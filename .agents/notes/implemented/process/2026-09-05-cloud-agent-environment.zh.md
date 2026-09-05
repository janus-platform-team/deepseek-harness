# Agent Note: Cursor Cloud Agent 开发环境

Status: implemented

[English](2026-09-05-cloud-agent-environment.md) | 中文

## 问题

Cursor Cloud Agent 会在全新 VM 上启动，且没有已提交的环境描述，因此每个 agent 都要重新推导如何安装、构建并运行本 harness。三个 VM 特有的摩擦点会让朴素的 `pnpm install && pnpm run build && pnpm dsh web` 失败。

`PATH` 上的默认 `node`（`/exec-daemon/node`）低于所要求的 `^22.19.0 || >=24.0.0`，而 exec-daemon 会把自身目录插到任何 shell profile 编辑之前，因此满足该范围的 nvm 构建单靠自身无法在 `PATH` 上胜出。

Cursor 通过 `core.hooksPath` 运行自己的 agent 钩子，因此本仓库的 lefthook `postinstall` 拒绝替换该路径并导致安装失败。

pnpm 在每次 `pnpm run` 前都会重新运行 `pnpm install` 以校验依赖，而始终「不受支持」的 `linux-arm64` 可选原生包会让该校验不断重装，从而在每条命令上重新触发相同的 lefthook 失败。

## 决策

`.cursor/environment.json` 在默认基础镜像上描述一个由仓库管理的 Cloud Agent 环境：`install` 运行 `.cursor/install.sh`，一个 `dsh-web` terminal 提供 Web UI，端口 `3080` 对外暴露。

`.cursor/install.sh` 是幂等的，执行四个步骤。

- 它选择已安装且满足 `^22.19.0 || >=24.0.0` 的最新 nvm Node，并将 `node`、`pnpm` 及其同级命令软链接到可写且高优先级的 `/usr/local/cargo/bin`——它在 `PATH` 上位于 `/exec-daemon` 之前——从而让每个 shell（包括 agent 自己的 shell）都运行兼容的运行时；pnpm 的 `#!/usr/bin/env node` shim 随之也解析到它。
- 它在全局 pnpm 配置中设置 `verify-deps-before-run=false`，使 `pnpm run` 信任本脚本安装的依赖，而不是在每条命令前重装。
- 它运行 `CI=true pnpm install --frozen-lockfile`；`CI=true` 是仓库自身的信号，使 `postinstall` 跳过 lefthook，而非与 Cursor 的 `core.hooksPath` 冲突。
- 它运行 `pnpm run build`，生成 Web UI 所服务的运行时与客户端产物。

`dsh-web` terminal 会加载 nvm、选择 Node 22 并运行 `pnpm dsh web --no-open`，后者会打印带 token 的 `http://127.0.0.1:3080/` URL。模型响应需要 `DEEPSEEK_API_KEY`，通过 Cloud Agent secret 提供；没有它服务器仍能启动并渲染。

## 曾考虑的替代方案

**为所有 shell 导出 `CI=true`。** 这会在各处跳过 lefthook，但也会在交互式 agent 工作期间切换 vitest 报告器及其他仅限 CI 的行为；将 `CI=true` 限定在安装步骤可保持普通 shell 不变。

**设置 `DSH_LEFTHOOK_ALLOW_HOOKS_PATH_OVERRIDE=1`。** 这会让 lefthook 安装其 worktree 钩子，但 worktree 作用域的 `core.hooksPath` 随后会为该检出遮蔽 Cursor 的 agent 钩子；跳过 lefthook 则保持 Cursor 的钩子不受影响。

**在 shell profile 中将 nvm bin 前置到 `PATH`，而非软链接。** exec-daemon 会在 profile 文件运行之后再前置 `/exec-daemon`，因此 profile 编辑无法为 agent 自己的 shell 胜出；而一个本已位于 `/exec-daemon` 之前的目录可以。

**提交带 `verify-deps-before-run=false` 的仓库 `.npmrc`。** 那会改变每个开发者以及 CI 的依赖行为，而不仅是 Cloud Agent；该设置应属于环境的全局 pnpm 配置。

## 后果

全新的 Cloud Agent 无需手动步骤即可安装、构建并提供 Web UI，且该描述随仓库一起版本化，因而会跟随分支与拉取请求。

Cloud Agent VM 中不安装 lefthook git 钩子；Cursor 自己的钩子保持活跃，而 CI 仍强制执行 lefthook 本会在本地运行的门禁。

Node 与 pnpm 软链接依赖 `/usr/local/cargo/bin` 可写且在 `PATH` 上位于 `/exec-daemon` 之前；脚本会守卫该写入，并在该目录不可用时回退到前置的 `PATH`。
