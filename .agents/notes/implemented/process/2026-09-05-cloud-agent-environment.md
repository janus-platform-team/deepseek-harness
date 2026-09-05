# Agent Note: Cursor Cloud Agent development environment

Status: implemented

English | [中文](2026-09-05-cloud-agent-environment.zh.md)

## Problem

Cursor Cloud Agents boot a fresh VM with no committed environment description, so each agent re-derives how to install, build, and run the harness. Three VM-specific frictions break a naive `pnpm install && pnpm run build && pnpm dsh web`.

The default `node` on `PATH` (`/exec-daemon/node`) is older than the required `^22.19.0 || >=24.0.0`, and the exec-daemon injects its directory ahead of any shell-profile edit, so an nvm build that satisfies the range never wins on `PATH` by itself.

Cursor owns `core.hooksPath` to run its own agent hooks, so the repository's lefthook `postinstall` refuses to replace that path and fails the install.

pnpm re-runs `pnpm install` before every `pnpm run` to verify dependencies, and the perpetually "unsupported" `linux-arm64` optional native package keeps that check reinstalling, re-triggering the same lefthook failure on every command.

## Decision

`.cursor/environment.json` describes a repository-managed Cloud Agent environment on the default base image: `install` runs `.cursor/install.sh`, a `dsh-web` terminal serves the Web UI, and port `3080` is exposed.

`.cursor/install.sh` is idempotent and performs four steps.

- It selects the newest installed nvm Node satisfying `^22.19.0 || >=24.0.0` and symlinks `node`, `pnpm`, and their siblings into the writable, high-priority `/usr/local/cargo/bin`, which precedes `/exec-daemon` on `PATH`, so every shell — including the agent's own — runs the compatible runtime; pnpm's `#!/usr/bin/env node` shim then also resolves to it.
- It sets `verify-deps-before-run=false` in the global pnpm config so `pnpm run` trusts the dependencies this script installs instead of reinstalling before each command.
- It runs `CI=true pnpm install --frozen-lockfile`; `CI=true` is the repository's own signal that makes `postinstall` skip lefthook rather than fight Cursor's `core.hooksPath`.
- It runs `pnpm run build` to produce the runtime and client artifacts the Web UI serves.

The `dsh-web` terminal sources nvm, selects Node 22, and runs `pnpm dsh web --no-open`, which prints a tokenized `http://127.0.0.1:3080/` URL. Model responses need `DEEPSEEK_API_KEY`, supplied as a Cloud Agent secret; the server boots and renders without one.

## Alternatives considered

**Export `CI=true` for all shells.** This skips lefthook everywhere but also switches vitest reporters and other CI-only behavior during interactive agent work; scoping `CI=true` to the install step keeps normal shells unchanged.

**Set `DSH_LEFTHOOK_ALLOW_HOOKS_PATH_OVERRIDE=1`.** This lets lefthook install its worktree hooks, but a worktree-scoped `core.hooksPath` then shadows Cursor's agent hooks for the checkout; skipping lefthook leaves Cursor's hooks intact.

**Prepend the nvm bin to `PATH` in a shell profile instead of symlinking.** The exec-daemon prepends `/exec-daemon` after profile files run, so a profile edit does not win for the agent's own shells; a directory that already precedes `/exec-daemon` does.

**Commit a repository `.npmrc` with `verify-deps-before-run=false`.** That would change dependency behavior for every developer and for CI, not just the Cloud Agent; the setting belongs in the environment's global pnpm config.

## Consequences

A fresh Cloud Agent installs, builds, and serves the Web UI without manual steps, and the description is versioned with the repository so it follows branches and pull requests.

lefthook git hooks are not installed in Cloud Agent VMs; Cursor's own hooks stay active, and CI still enforces the gates lefthook would otherwise run locally.

The Node and pnpm symlinks depend on `/usr/local/cargo/bin` being writable and ahead of `/exec-daemon` on `PATH`; the script guards the write and falls back to the prepended `PATH` when the directory is unavailable.
