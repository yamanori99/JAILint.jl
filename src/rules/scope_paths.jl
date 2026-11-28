# Built-in `scope-paths`: trusted `--allow-paths` gate (diff only).

function compile_allow_path_globs(raw::Vector{String})
    isempty(raw) &&
        throw(ConfigError("--allow-paths requires at least one non-empty glob"))
    out = Regex[]
    for (j, g) in enumerate(raw)
        label = "allow-paths[$j]"
        given = strip(String(g))
        isempty(given) && throw(ConfigError("--allow-paths: empty glob at index $j"))
        pat = normalize_path(given)
        validate_path_glob_pattern!(pat, label)
        push!(out, compile_path_glob(pat, label))
    end
    return out
end

function parse_allow_paths_cli(raw::AbstractString)
    s = strip(String(raw))
    isempty(s) && throw(ConfigError("--allow-paths requires a non-empty glob list"))
    raw_parts = String[strip(p) for p in split(s, ',')]
    isempty(raw_parts) && throw(ConfigError("--allow-paths requires a non-empty glob list"))
    all(isempty, raw_parts) && throw(ConfigError("--allow-paths requires a non-empty glob list"))
    filter!(!isempty, raw_parts)
    return raw_parts
end

function _scope_paths_spec(policy::PolicyBundle)
    spec = get(policy.rules, SCOPE_PATHS_RULE, nothing)
    spec === nothing &&
        throw(InternalError("built-in rule $SCOPE_PATHS_RULE missing from policy"))
    return spec
end

function _scope_paths_diag(path::String, message::String, policy::PolicyBundle)
    spec = _scope_paths_spec(policy)
    return Violation(
        SCOPE_PATHS_RULE,
        Origin.AGENTRULELINT,
        spec.level,
        path,
        Span(1, 1, 1, 1),
        1,
        "",
        ExpectStatus.NONE,
        false,
        message,
        spec.intent,
        spec.do_not,
    )
end

function _path_matches_allowlist(path::AbstractString, allow_regexes::Vector{Regex})
    p = normalize_path(path)
    return any(r -> occursin(r, p), allow_regexes)
end

function _event_paths(ev::DiffPathEvent)
    return ev.status in ('R', 'C') ? (ev.old_path, ev.path) : (ev.path,)
end

"""
    enforce_scope_paths(events, allow_regexes, policy)

Every changed path (including deletes and both sides of renames) must match an allow glob.
"""
function enforce_scope_paths(events::Vector{DiffPathEvent}, allow_regexes::Vector{Regex}, policy::PolicyBundle)
    _scope_paths_spec(policy)
    out = Violation[]
    seen = Set{String}()
    for ev in events
        for p in _event_paths(ev)
            p in seen && continue
            push!(seen, p)
            _path_matches_allowlist(p, allow_regexes) && continue
            msg = "change outside --allow-paths scope"
            push!(out, _scope_paths_diag(p, msg, policy))
        end
    end
    return out
end

function validate_allow_paths_kw(allow_paths, diff_base)
    allow_paths === nothing && return nothing
    diff_base === nothing &&
        throw(ConfigError("--allow-paths requires --diff (trusted scope mode)"))
    return allow_paths
end

const _SCOPE_PATHS_EXPLAIN_DETAIL = """
Group: integrity. Level: forbid (no inline expects).

Active only when `check` receives `--allow-paths GLOB,...` together with `--diff <base>`.
The allowlist is accepted only from the CLI or the `check(...; allow_paths=...)` keyword,
never from `$CONFIG_FILENAME`, so only a trusted CI workflow input or human wrapper
can widen scope.

Every changed path in the diff (add, modify, delete, rename on both sides) must match at
least one glob. Otherwise the rule flags the path.

Without `--diff`, `--allow-paths` is a usage error (exit 2). An empty or whitespace-only
list is a usage error. Globs are normalized at the input boundary (`\\` is a path separator).
Absolute paths and `..` segments are rejected at glob parse time (exit 2).

Integrity level: `scope-paths` must use `level = "forbid"` in config (ConfigError otherwise).
"""

function scope_paths_explain_extra()
    return Dict{Symbol, String}(:detail => strip(_SCOPE_PATHS_EXPLAIN_DETAIL))
end

const SCOPE_PATHS_RULE_DEF = RuleDef(
    SCOPE_PATHS_RULE,
    Origin.AGENTRULELINT,
    Level.FORBID,
    "Reject diff changes outside a trusted path allowlist.",
    "Edit files outside --allow-paths scope passed from CI or a human wrapper.",
    Dict{Symbol, String}(),
    "scope_paths.jl",
    "test_scope_paths.jl",
    ("test/corpus/scope_paths_outside_allow.jl",),
)
