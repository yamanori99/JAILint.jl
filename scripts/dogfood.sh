#!/usr/bin/env bash
# Run AgentRuleLint check --diff using the base-branch linter package (dogfood).
#
#   ./scripts/dogfood.sh [BASE_REF [OUTPUT_DIR [FORMATS]]]
#
# BASE_REF defaults to origin/main (CI: origin/${GITHUB_BASE_REF}).
# OUTPUT_DIR defaults to a fresh mktemp -d (never a fixed shared path).
# FORMATS defaults to human,json (comma-separated). No option weakens policy.
#
# Optional env: DOGFOOD_REPO, DOGFOOD_HEAD, DOGFOOD_PR_NUMBER, DOGFOOD_HEAD_SHA,
# DOGFOOD_JULIA (default julia +1.13), PR_NUMBER, HEAD_SHA (CI).
#
# Test-only env (hermetic tests in test/test_dogfood_script.jl):
#   DOGFOOD_TEST_SKIP_PKG_SETUP=1, DOGFOOD_TEST_FAIL_SETUP=1,
#   DOGFOOD_TEST_CHECK_CMD=/path/to/stub
#
set -euo pipefail

root="${DOGFOOD_REPO:-$(
  cd "$(dirname "$0")/.." && pwd
)}"
cd "$root"

BASE_REF="${1:-origin/main}"
if [[ -n "${2:-}" ]]; then
  OUTPUT_DIR="$2"
  mkdir -p "${OUTPUT_DIR}"
else
  OUTPUT_DIR="$(mktemp -d)"
fi
FORMATS_CSV="${3:-human,json}"

DOGFOOD_HEAD="${DOGFOOD_HEAD:-HEAD}"
JULIA_CMD=(julia +1.13)
if [[ -n "${DOGFOOD_JULIA:-}" ]]; then
  # shellcheck disable=SC2206
  JULIA_CMD=(${DOGFOOD_JULIA})
fi

WORKTREE_PARENT=""
LINTER_WT=""

trap '
  if [[ -n "${LINTER_WT:-}" ]]; then
    git worktree remove -f "${LINTER_WT}" 2>/dev/null || true
  fi
  if [[ -n "${WORKTREE_PARENT:-}" ]] && [[ -d "${WORKTREE_PARENT}" ]]; then
    rm -rf "${WORKTREE_PARENT}"
  fi
' EXIT

die() {
  echo "dogfood: $*" >&2
  exit 1
}

want_format() {
  local want="$1"
  local f
  IFS=',' read -ra _fmts <<< "${FORMATS_CSV}"
  for f in "${_fmts[@]}"; do
    f="${f#"${f%%[![:space:]]*}"}"
    f="${f%"${f##*[![:space:]]}"}"
    [[ "${f}" == "${want}" ]] && return 0
  done
  return 1
}

if [[ "${BASE_REF}" == origin/* ]]; then
  remote_ref="${BASE_REF#origin/}"
  git fetch origin "${remote_ref}" --no-tags || die "fetch failed for origin/${remote_ref}"
else
  git rev-parse --verify "${BASE_REF}" >/dev/null 2>&1 || die "missing base ref ${BASE_REF}"
fi

WORKTREE_PARENT="$(mktemp -d)"
LINTER_WT="${WORKTREE_PARENT}/linter-base"
git worktree add --detach "${LINTER_WT}" "${BASE_REF}" || die "worktree add failed for ${BASE_REF}"

linter_sha="$(git -C "${LINTER_WT}" rev-parse HEAD)"
base_tip="$(git rev-parse "${BASE_REF}")"
[[ "${linter_sha}" == "${base_tip}" ]] || die "linter worktree HEAD ${linter_sha} != base tip ${base_tip}"

if [[ "${DOGFOOD_TEST_FAIL_SETUP:-}" == "1" ]]; then
  die "instantiate/precompile failed"
elif [[ "${DOGFOOD_TEST_SKIP_PKG_SETUP:-}" == "1" ]]; then
  :
else
  JULIA_LOAD_PATH="@:@stdlib" "${JULIA_CMD[@]}" --startup-file=no --project="${LINTER_WT}" \
    -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()' || die "instantiate/precompile failed"
fi

base_sha="$(git merge-base "${BASE_REF}" "${DOGFOOD_HEAD}")"
linter_sha="$(git -C "${LINTER_WT}" rev-parse HEAD)"
pkg_version="$(sed -n -E 's/^version = "([^"]+)".*/\1/p' "${LINTER_WT}/Project.toml" | head -1)"
julia_version="$("${JULIA_CMD[@]}" --version 2>/dev/null | sed -n 's/^julia version \([^ ]*\).*/\1/p' || true)"

run_check() {
  local fmt="$1"
  if [[ -n "${DOGFOOD_TEST_CHECK_CMD:-}" ]]; then
    export DOGFOOD_CHECK_FORMAT="${fmt}"
    export DOGFOOD_CHECK_DIFF="${base_sha}"
    export DOGFOOD_CHECK_CONFIG_FROM="${BASE_REF}"
    export DOGFOOD_OUTPUT_DIR="${OUTPUT_DIR}"
    "${DOGFOOD_TEST_CHECK_CMD}"
    return $?
  fi
  if [[ "${fmt}" == "json" ]]; then
    JULIA_LOAD_PATH="@:@stdlib" "${JULIA_CMD[@]}" --startup-file=no --project="${LINTER_WT}" -m AgentRuleLint check \
      --diff "${base_sha}" \
      --config-from "${BASE_REF}" \
      --format json \
      --output "${OUTPUT_DIR}/dogfood.jsonl" 2> "${OUTPUT_DIR}/json.stderr"
    return $?
  fi
  JULIA_LOAD_PATH="@:@stdlib" "${JULIA_CMD[@]}" --startup-file=no --project="${LINTER_WT}" -m AgentRuleLint check \
    --diff "${base_sha}" \
    --config-from "${BASE_REF}" \
    --format "${fmt}" > "${OUTPUT_DIR}/${fmt}.log"
  return $?
}

human_exit=0
json_exit=0

if want_format human; then
  set +e
  run_check human
  human_exit=$?
  set -e
fi

if want_format json; then
  set +e
  run_check json
  json_exit=$?
  set -e
fi

IFS=',' read -ra _all_fmts <<< "${FORMATS_CSV}"
for fmt in "${_all_fmts[@]}"; do
  fmt="${fmt#"${fmt%%[![:space:]]*}"}"
  fmt="${fmt%"${fmt##*[![:space:]]}"}"
  [[ -z "${fmt}" ]] && continue
  [[ "${fmt}" == "human" || "${fmt}" == "json" ]] && continue
  set +e
  run_check "${fmt}"
  set -e
done

if ! want_format human; then
  human_exit="${json_exit}"
fi

pr_number="${DOGFOOD_PR_NUMBER:-${PR_NUMBER:-}}"
head_sha="${DOGFOOD_HEAD_SHA:-${HEAD_SHA:-}}"
if [[ -z "${head_sha}" ]]; then
  head_sha="$(git rev-parse "${DOGFOOD_HEAD}" 2>/dev/null || true)"
fi

base_ref_name="${BASE_REF#origin/}"

jq -n \
  --arg prn "${pr_number}" \
  --arg head_sha "${head_sha}" \
  --arg merge_base_sha "${base_sha}" \
  --arg base_ref "${base_ref_name}" \
  --arg linter_commit_sha "${linter_sha}" \
  --arg package_version "${pkg_version}" \
  --arg julia_version "${julia_version}" \
  --argjson human_exit_code "${human_exit}" \
  --argjson json_exit_code "${json_exit}" \
  '{
    pr_number: (if $prn == "" then null else ($prn | tonumber) end),
    head_sha: $head_sha,
    merge_base_sha: $merge_base_sha,
    base_ref: $base_ref,
    linter_commit_sha: $linter_commit_sha,
    package_version: $package_version,
    julia_version: $julia_version,
    human_exit_code: $human_exit_code,
    json_exit_code: $json_exit_code
  }' > "${OUTPUT_DIR}/meta.json"

if want_format human && [[ -f "${OUTPUT_DIR}/human.log" ]]; then
  cat "${OUTPUT_DIR}/human.log"
fi

echo "dogfood: exit=${human_exit} dir=${OUTPUT_DIR}"
exit "${human_exit}"
