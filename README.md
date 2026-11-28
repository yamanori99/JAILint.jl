# AgentRuleLint.jl

<!-- markdownlint-disable MD013 -->
[![Status](https://img.shields.io/badge/status-0.1.0--DEV-orange?style=flat-square)](https://github.com/yamanori99/AgentRuleLint.jl)
[![Test](https://img.shields.io/github/actions/workflow/status/yamanori99/AgentRuleLint.jl/CI.yml?branch=main&style=flat-square&logo=githubactions&logoColor=white&label=Test)](https://github.com/yamanori99/AgentRuleLint.jl/actions/workflows/CI.yml)
[![Codecov](https://img.shields.io/codecov/c/github/yamanori99/AgentRuleLint.jl?style=flat-square&logo=codecov&logoColor=white)](https://codecov.io/gh/yamanori99/AgentRuleLint.jl)
[![Julia 1.13+](https://img.shields.io/badge/Julia-1.13+-9558B2?style=flat-square&logo=julia&logoColor=white)](https://julialang.org/)
[![code style: runic](https://img.shields.io/badge/code_style-%E1%9A%B1%E1%9A%A2%E1%9A%BE%E1%9B%81%E1%9A%B2-black)](https://github.com/fredrikekre/Runic.jl)
[![License](https://img.shields.io/badge/License-MIT-yellow?style=flat-square)](LICENSE)
<!-- markdownlint-enable MD013 -->

**AgentRuleLint.jl** is a static linter and CI guardrail harness for Julia
repositories worked on with AI coding agents. It enforces invariants and agent
policy rules, and catches shortcuts such as lint evasion, silent fallbacks, and
weakened tests.

> [!NOTE]
> **0.1.0-DEV** (not registered in General). Rules were first exercised in
> [DistSSHRun.jl](https://github.com/yamanori99/DistSSHRun.jl) and are being
> extracted into a standalone package.

## Quick start

```sh
julia -e 'using Pkg; Pkg.Apps.add(url="https://github.com/yamanori99/AgentRuleLint.jl")'

cd path/to/your/repo
agentrulelint check
agentrulelint check --diff origin/main
agentrulelint explain <rule-id>
```

Assuming `~/.julia/bin` is in your `PATH` you can invoke `agentrulelint` from
your shell (or `pkg> app add https://github.com/yamanori99/AgentRuleLint.jl` in
the Pkg REPL).

Exit 0 means no finding at or above the threshold (default `warn`), 1 means at
least one, 2 a config or usage error, 3 an internal error. `exit_severity` in the config, or
`--exit-severity` for one run, raises the threshold to `deny` or `forbid`;
`forbid` findings always fail, and a CLI override is shown in the verdict line.

AgentRuleLint uses the **git bundled through [Git.jl](https://github.com/JuliaIO/Git.jl)** (minimum
**2.32**). You do not need git installed on the host. User and system git config and attributes are
ignored (`GIT_CONFIG_NOSYSTEM`, empty global config, `GIT_ATTR_NOSYSTEM`, `core.attributesFile`).
The resolved git path and version appear in human, agent, and JSON output headers. Plain `check` needs a
git repository for **manifest-sync**
(tracked `Project.toml` / `Manifest.toml` pairs). **`check --diff`** loads lint policy from the diff
base ref by default (same ref as the file scope; use **`--worktree-config`**, **`--config`**, or
**`--config-from`** to override). Ceiling ratchet, protected-path base comparison, and scope-paths
also read git history. Only the repository
root you pass is trusted via `safe.directory` (not worktrees or submodules as separate roots).

Agents run `agentrulelint check --format agent`.
Run `agentrulelint explain <rule-id>` for a rule's level, intent, and
configuration.

Read [AGENTS.md](AGENTS.md) before changing rules or silencing diagnostics.
Further detail: [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md),
[LICENSE](LICENSE).
