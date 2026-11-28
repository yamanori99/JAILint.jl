#!/usr/bin/env bash
# Trailing-newline audit on all tracked text files and git diff --check on a commit range.
#
#   WHITESPACE_GATE_DIFF_RANGE='origin/main...HEAD' ./scripts/whitespace-gate.sh
#
# Range rule (WHITESPACE_GATE_DIFF_RANGE overrides everything):
#   pull_request CI: origin/${GITHUB_BASE_REF}...HEAD
#   push CI: ${GITHUB_BEFORE}..${GITHUB_SHA} (empty GITHUB_BEFORE = new branch; diff --check skipped, printed)
#   local: origin/main...HEAD when that ref exists; otherwise exit 1 (set WHITESPACE_GATE_DIFF_RANGE)
#
# Binary paths are skipped using git's numstat/git-grep -I heuristics (no extension list).
set -euo pipefail

root="${WHITESPACE_GATE_REPO:-$(
  cd "$(dirname "$0")/.." && pwd
)}"
cd "$root"

EMPTY_SHA="0000000000000000000000000000000000000000"

# Explicit path exclusions: one entry per line as path<TAB>reason (no globs).
# shellcheck disable=SC2034
declare -a EXCLUSIONS=(
  $'test/goldens/output/check_agent.txt\tgolden reproduces --format agent output byte-for-byte; output ends with a blank line (to be decided separately)'
  $'test/goldens/output/minimal_config/check_agent.txt\tgolden reproduces --format agent output byte-for-byte; output ends with a blank line (to be decided separately)'
  $'test/goldens/output/no_config/check_agent.txt\tgolden reproduces --format agent output byte-for-byte; output ends with a blank line (to be decided separately)'
)

declare -a NEWLINE_FAILURES=()
DIFF_CHECK_RANGE=""
DIFF_CHECK_SKIP_REASON=""

is_excluded() {
  local f="$1"
  local entry
  for entry in "${EXCLUSIONS[@]}"; do
    [[ "${entry%%$'\t'*}" == "$f" ]] && return 0
  done
  return 1
}

is_binary_tracked() {
  local f="$1"
  local ns
  ns="$(git diff --numstat HEAD -- "$f" 2>/dev/null | head -1 || true)"
  [[ -n "$ns" && "$ns" == -* ]]
}

is_text_tracked() {
  local f="$1"
  is_binary_tracked "$f" && return 1
  git grep -I -q . -- "$f" 2>/dev/null && return 0
  git grep -I -q '^' -- "$f" 2>/dev/null && return 0
  local sz
  sz="$(git cat-file -s "HEAD:$f" 2>/dev/null || echo 1)"
  [[ "${sz}" -eq 0 ]]
}

audit_trailing_newline() {
  local f path size last_oct last_two_oct
  while IFS= read -r -d '' f; do
    is_excluded "$f" && continue
    is_text_tracked "$f" || continue
    path="${root}/${f}"
    [[ -f "$path" ]] || continue
    size="$(wc -c <"${path}" | tr -d ' ')"
    if [[ "${size}" -eq 0 ]]; then
      NEWLINE_FAILURES+=("empty text file (expected a single trailing newline): ${f}")
      continue
    fi
    # Do not use $(tail -c 1): command substitution strips a trailing newline on macOS.
    last_oct="$(tail -c 1 "${path}" | od -An -tu1 | tr -d ' [:space:]')"
    if [[ -z "${last_oct}" ]] || [[ "${last_oct}" != "10" ]]; then
      NEWLINE_FAILURES+=("missing final newline: ${f}")
      continue
    fi
    last_two_oct="$(tail -c 2 "${path}" | od -An -tu1 | tr -d ' [:space:]')"
    if [[ "${last_two_oct}" == "1010" ]]; then
      NEWLINE_FAILURES+=("multiple trailing newlines: ${f}")
    fi
  done < <(git ls-files -z)
}

diff_range_usable() {
  local range="$1"
  [[ -n "${range}" ]] || return 1
  if [[ "${range}" == *"..."* ]]; then
    local left="${range%%...*}"
    local right="${range#*...}"
    git rev-parse --verify "${left}" >/dev/null 2>&1 &&
      git rev-parse --verify "${right}" >/dev/null 2>&1
    return $?
  fi
  if [[ "${range}" == *".."* ]]; then
    local left="${range%%..*}"
    local right="${range#*..}"
    git rev-parse --verify "${left}" >/dev/null 2>&1 &&
      git rev-parse --verify "${right}" >/dev/null 2>&1
    return $?
  fi
  git rev-parse --verify "${range}" >/dev/null 2>&1
}

choose_diff_range() {
  DIFF_CHECK_RANGE=""
  DIFF_CHECK_SKIP_REASON=""

  if [[ -n "${WHITESPACE_GATE_DIFF_RANGE:-}" ]]; then
    if diff_range_usable "${WHITESPACE_GATE_DIFF_RANGE}"; then
      DIFF_CHECK_RANGE="${WHITESPACE_GATE_DIFF_RANGE}"
      return 0
    fi
    echo "whitespace-gate: unusable WHITESPACE_GATE_DIFF_RANGE=${WHITESPACE_GATE_DIFF_RANGE}" >&2
    exit 1
  fi

  if [[ "${GITHUB_EVENT_NAME:-}" == "pull_request" && -n "${GITHUB_BASE_REF:-}" ]]; then
    git fetch origin "${GITHUB_BASE_REF}" --no-tags
    local pr_range="origin/${GITHUB_BASE_REF}...HEAD"
    if diff_range_usable "${pr_range}"; then
      DIFF_CHECK_RANGE="${pr_range}"
      return 0
    fi
    echo "whitespace-gate: unusable pull_request diff range ${pr_range}" >&2
    exit 1
  fi

  if [[ "${GITHUB_EVENT_NAME:-}" == "push" ]]; then
    if [[ "${GITHUB_BEFORE:-}" == "${EMPTY_SHA}" ]]; then
      DIFF_CHECK_SKIP_REASON="push event with empty GITHUB_BEFORE (new branch)"
      return 0
    fi
    if [[ -z "${GITHUB_BEFORE:-}" ]]; then
      echo "whitespace-gate: push event missing GITHUB_BEFORE; set WHITESPACE_GATE_DIFF_RANGE" >&2
      exit 1
    fi
    local push_range="${GITHUB_BEFORE}..${GITHUB_SHA:-HEAD}"
    if diff_range_usable "${push_range}"; then
      DIFF_CHECK_RANGE="${push_range}"
      return 0
    fi
    echo "whitespace-gate: unusable push diff range ${push_range}" >&2
    exit 1
  fi

  if diff_range_usable "origin/main...HEAD"; then
    DIFF_CHECK_RANGE="origin/main...HEAD"
    return 0
  fi

  echo "whitespace-gate: cannot determine git diff --check range; set WHITESPACE_GATE_DIFF_RANGE" >&2
  exit 1
}

run_diff_check() {
  choose_diff_range
  if [[ -n "${DIFF_CHECK_RANGE}" ]]; then
    echo "whitespace-gate: git diff --check range: ${DIFF_CHECK_RANGE}"
    git diff --check "${DIFF_CHECK_RANGE}"
    return 0
  fi
  if [[ -n "${DIFF_CHECK_SKIP_REASON}" ]]; then
    echo "whitespace-gate: git diff --check range: <none> (${DIFF_CHECK_SKIP_REASON})"
    return 0
  fi
  echo "whitespace-gate: git diff --check range: <none>"
  return 0
}

audit_trailing_newline

if ((${#NEWLINE_FAILURES[@]} > 0)); then
  echo "whitespace-gate: trailing newline audit failed (${#NEWLINE_FAILURES[@]} file(s)):" >&2
  printf '%s\n' "${NEWLINE_FAILURES[@]}" >&2
  exit 1
fi

run_diff_check
echo "whitespace-gate: ok"
