#!/usr/bin/env bash
# Cloud Agent repository bootstrap for DeepSeek Harness.
# Idempotent: safe to run repeatedly against cached or partially prepared state.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

# The harness requires Node "^22.19.0 || >=24.0.0", but the VM's default `node`
# (/exec-daemon/node) is older. nvm ships a compatible build. Resolve its real
# binary directly (never through the PATH shim managed below, which would make a
# self-referential symlink) by choosing the newest installed nvm Node that
# satisfies the engine range.
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
NODE_EXE=""
for candidate in $(ls -d "$NVM_DIR"/versions/node/v*/bin/node 2>/dev/null | sort -V -r); do
  version="$("$candidate" --version 2>/dev/null | sed 's/^v//')"
  [ -n "$version" ] || continue
  major="${version%%.*}"
  rest="${version#*.}"
  minor="${rest%%.*}"
  if { [ "$major" -eq 22 ] && [ "$minor" -ge 19 ]; } || [ "$major" -ge 24 ]; then
    NODE_EXE="$candidate"
    break
  fi
done
if [ -z "$NODE_EXE" ]; then
  echo "install: no nvm Node satisfying ^22.19.0 || >=24.0.0 found under $NVM_DIR" >&2
  exit 1
fi
NODE_BIN_DIR="$(dirname "$NODE_EXE")"
export PATH="$NODE_BIN_DIR:$PATH"

# Make the compatible runtime the first node/pnpm on PATH for every shell,
# including the agent's own shells whose PATH puts /usr/local/cargo/bin ahead of
# /exec-daemon. pnpm's `#!/usr/bin/env node` shim then also runs under it.
SHIM_DIR=/usr/local/cargo/bin
if [ -d "$SHIM_DIR" ] && [ -w "$SHIM_DIR" ] && [ "$SHIM_DIR" != "$NODE_BIN_DIR" ]; then
  for exe in node npm npx corepack pnpm pnpx; do
    if [ -x "$NODE_BIN_DIR/$exe" ]; then
      ln -sf "$NODE_BIN_DIR/$exe" "$SHIM_DIR/$exe"
    fi
  done
fi

node --version
pnpm --version

# `pnpm run <script>` otherwise re-runs `pnpm install` before every command to
# verify dependencies; the always-"unsupported" linux-arm64 optional native
# package keeps that check reinstalling. Dependencies are installed here, so
# turn the pre-run verification off globally for the environment.
pnpm config set verify-deps-before-run false --location=global

# Cursor owns git hooks through core.hooksPath; the repo's postinstall refuses
# to replace that path unless CI=true, in which case it skips lefthook cleanly.
CI=true pnpm install --frozen-lockfile

# Build the runtime and client artifacts that `pnpm dsh web` serves.
pnpm run build
