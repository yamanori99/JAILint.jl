---
name: pre-push-gate
description: >
  Final-tree verification before push. Use when preparing a commit or pull request
  for AgentRuleLint.jl, or when asked to run the local agent gate.
---

# Pre-push gate

Run on the exact tree you will push, Julia **`+1.13`**, with no further edits afterward.

## Always

1. `runic --check --diff .` using the pin in `.github/runic/Project.toml`.
2. `./scripts/whitespace-gate.sh` (tracked text files end with a single newline; `git diff --check` on the same commit range CI uses).
3. `./.github/jetls-check.sh` (`jetls check --exit-severity=hint`).
4. `git merge-tree --write-tree origin/main HEAD` must succeed with a clean tree.

## When scripts or workflows change

On touched `.sh` files and workflow YAML: `shellcheck`, `actionlint`,
`pinact run --fix=false --no-api`, `zizmor --offline --no-progress`.
Read `.github/actions-lint.env` before bumping tool versions.

## When the package tree exists

Dogfood (match the CI `dogfood` job: base-branch linter, not the working tree's `src/`):

```bash
set -euo pipefail
git fetch origin main
if [[ -e .linter-base ]]; then
  git worktree remove -f .linter-base
fi
git worktree add --detach .linter-base origin/main
JULIA_LOAD_PATH="@:@stdlib" julia +1.13 --startup-file=no --project=.linter-base -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'
set -o pipefail
JULIA_LOAD_PATH="@:@stdlib" julia +1.13 --startup-file=no --project=.linter-base -m AgentRuleLint check \
  --diff "$(git merge-base origin/main HEAD)" \
  --config-from origin/main \
  --format agent 2>&1 | tee /tmp/agentrulelint-dogfood.log
git worktree remove -f .linter-base
```

`.linter-base/` is listed in `.gitignore` and is not part of the PR diff; dogfood
uses `--diff` only.

Read the **entire** `tee` output (or `/tmp/agentrulelint-dogfood.log`). Do **not**
use `tail`; the closing summary line does not repeat every `HIT` with path and
span — you need the full agent format body to locate and fix each finding.

Expect only `protected-paths` on PRs that touch protected files; fix every other
finding before push.

```bash
set -o pipefail; JULIA_LOAD_PATH="@:@stdlib" julia +1.13 --startup-file=no --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tee /tmp/agentrulelint-test.log
```

Confirm Aqua and `test/test_runic_invariance.jl`. The command's exit status is
the suite result. Then:

```bash
JULIA_LOAD_PATH="@:@stdlib" julia +1.13 --startup-file=no --project=. test/mutation/run_all.jl
```

Every harness must PASS. On `Pkg.test` failure, read the digest at the end of
the log or `test/last_failures.txt`. Do not re-run the full suite only to see
which tests failed.

List discovered per-file tests:

```bash
JULIA_LOAD_PATH="@:@stdlib" julia +1.13 --startup-file=no --project=. -e 'using Pkg; Pkg.test(test_args=["--list"])'
```

Re-run one file by name (example: `test_output_formats`), then the full suite
once on the final tree:

```bash
JULIA_LOAD_PATH="@:@stdlib" julia +1.13 --startup-file=no --project=. -e 'using Pkg; Pkg.test(test_args=["test_output_formats"])'
set -o pipefail; JULIA_LOAD_PATH="@:@stdlib" julia +1.13 --startup-file=no --project=. -e 'using Pkg; Pkg.test()' 2>&1 | tee /tmp/agentrulelint-test.log
```

## Hygiene

- No `exit()` in library code (`src/`).
- Never persist `HOME` or `JULIA_DEPOT_PATH` in the shell profile; prefix per command only.
- Do not weaken a check or hollow a test to get green CI.

Install missing pinned apps only when the person asked (`./.github/install-agent-tools.sh`).
