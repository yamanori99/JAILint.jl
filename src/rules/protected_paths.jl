# Built-in `protected-paths` (diff-scoped integrity; no inline expects).

const CEILINGS_REL_PATH = CEILINGS_REL

const AUTO_PROTECTED_EXACT = Set(
    [
        CONFIG_FILENAME,
        LEGACY_CONFIG_FILENAME,
        ".JETLSConfig.toml",
        ".gitattributes",
        ".gitmodules",
        "JuliaManifest.toml",
        "LocalPreferences.toml",
    ],
)

function _is_manifest_lock(path::AbstractString)
    base = basename(String(path))
    return startswith(base, "Manifest") && endswith(base, ".toml")
end

function _is_workspace_project_toml(path::AbstractString)
    p = normalize_path(path)
    return endswith(p, "/Project.toml") || p == "Project.toml"
end

function _under_agentrulelint(path::AbstractString)
    p = normalize_path(path)
    return p == ".agentrulelint" || startswith(p, ".agentrulelint/")
end

function auto_protected_reason(path::AbstractString)
    p = normalize_path(path)
    (p == CONFIG_FILENAME || p == LEGACY_CONFIG_FILENAME) &&
        return "AgentRuleLint policy must not be weakened by agents."
    p == ".gitattributes" &&
        return "`.gitattributes` controls git diff and merge behavior and must not be weakened."
    p == ".gitmodules" &&
        return "`.gitmodules` submodule configuration requires explicit human review."
    _under_agentrulelint(p) && return "`.agentrulelint/` integrity files require explicit human review."
    p == ".JETLSConfig.toml" &&
        return "JETLS diagnostic settings require explicit human review."
    _is_manifest_lock(p) && return "Manifest lockfiles must not be edited without review."
    p == "JuliaManifest.toml" && return "JuliaManifest.toml must not be edited without review."
    p == "LocalPreferences.toml" &&
        return "LocalPreferences.toml must not be edited without review."
    _is_workspace_project_toml(p) &&
        return "Project.toml changes are limited to semantic deps/compat additions."
    return "protected path changed"
end

function _match_protected_glob_entry(path::AbstractString, policy::PolicyBundle)
    p = normalize_path(path)
    for entry in policy.protected_path_globs
        occursin(entry.regex, p) && return entry
    end
    return nothing
end

function _auto_classify_protected_path(path::AbstractString)
    p = normalize_path(path)
    p in AUTO_PROTECTED_EXACT && return true, auto_protected_reason(p)
    _under_agentrulelint(p) && return true, auto_protected_reason(p)
    _is_manifest_lock(p) && return true, auto_protected_reason(p)
    _is_workspace_project_toml(p) && return true, auto_protected_reason(p)
    return false, ""
end

function classify_protected_path(path::AbstractString, policy::PolicyBundle)
    entry = _match_protected_glob_entry(path, policy)
    entry !== nothing && return true, entry.reason
    return _auto_classify_protected_path(path)
end

function _glob_entry_for_event(ev::DiffPathEvent, policy::PolicyBundle)
    if ev.status in ('R', 'C')
        for p in (ev.old_path, ev.path)
            entry = _match_protected_glob_entry(p, policy)
            entry !== nothing && return entry
        end
        return nothing
    end
    return _match_protected_glob_entry(ev.path, policy)
end

function _path_matches_glob_entry(path::AbstractString, entry::ProtectedGlobEntry)
    return occursin(entry.regex, normalize_path(path))
end

function _on_allows(change_types::Union{Nothing, Set{String}}, word::AbstractString)
    change_types === nothing && return true
    return String(word) in change_types
end

function _filtered_glob_path_words(ev::DiffPathEvent, entry::ProtectedGlobEntry)
    st = ev.status
    old_p = ev.old_path
    new_p = ev.path
    old_m = _path_matches_glob_entry(old_p, entry)
    new_m = _path_matches_glob_entry(new_p, entry)
    if st == 'A'
        new_m || return Tuple{String, String}[]
        return [(new_p, "added")]
    elseif st == 'M'
        new_m || return Tuple{String, String}[]
        return [(new_p, "modified")]
    elseif st == 'D'
        new_m || return Tuple{String, String}[]
        return [(new_p, "deleted")]
    elseif st == 'R'
        out = Tuple{String, String}[]
        if old_m && !new_m
            push!(out, (old_p, "deleted"))
        elseif new_m && !old_m
            push!(out, (new_p, "added"))
        elseif old_m && new_m
            push!(out, (old_p, "renamed"))
            push!(out, (new_p, "renamed"))
        end
        return out
    elseif st == 'C'
        old_m && !new_m && return Tuple{String, String}[]
        new_m && !old_m && return [(new_p, "added")]
        old_m && new_m && return [(new_p, "copied")]
        return Tuple{String, String}[]
    end
    return Tuple{String, String}[]
end

function _protected_paths_spec(policy::PolicyBundle)
    spec = get(policy.rules, PROTECTED_PATHS_RULE, nothing)
    spec === nothing &&
        throw(InternalError("built-in rule $PROTECTED_PATHS_RULE missing from policy"))
    return spec
end

function _protected_paths_diag(path::String, message::String, policy::PolicyBundle)
    spec = _protected_paths_spec(policy)
    return Violation(
        PROTECTED_PATHS_RULE,
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

function _status_word(st::Char)
    st == 'A' && return "added"
    st == 'D' && return "deleted"
    st == 'R' && return "renamed"
    st == 'C' && return "copied"
    return "modified"
end

function _read_working_text(root::AbstractString, relpath::AbstractString)
    ap = joinpath(root, relpath)
    isfile(ap) || throw(ParseError("file not found: $relpath"))
    bytes = read(ap)
    isvalid(String, bytes) || throw(ParseError("file is not valid UTF-8: $relpath"))
    return String(bytes)
end

function _read_base_text(root::AbstractString, base::AbstractString, relpath::AbstractString)
    sha = git_resolve_commit_sha(root, base)
    git_tree_path_exists(root, sha, relpath) ||
        throw(ParseError("missing file at diff base: $relpath"))
    return git_show_blob_at_commit(root, sha, relpath)
end

function _parse_toml_policy!(text::AbstractString, label::AbstractString)
    return load_toml_string(String(text), label)
end

function _toml_equal(a, b)
    return a == b
end

"""
    project_toml_semantic_violations(base, head) -> Vector{String}

Semantic diff for protected `Project.toml` (0.1.0: compat compared by string equality only; no semver).
Allows new `[deps]` entries and new `[compat]` entries for those deps. Forbids `[sources]`, `[workspace]`,
compat removal/change, and any other top-level key change.
"""
function project_toml_semantic_violations(base::Dict, head::Dict)
    msgs = String[]
    base_deps = get(base, "deps", Dict{String, Any}())
    head_deps = get(head, "deps", Dict{String, Any}())
    base_compat = get(base, "compat", Dict{String, Any}())
    head_compat = get(head, "compat", Dict{String, Any}())

    new_dep_names = Set(String(k) for k in keys(head_deps) if !haskey(base_deps, k))
    for dep in keys(base_deps)
        String(dep) in keys(head_deps) || push!(msgs, "removed [deps] entry $(dep)")
        haskey(head_deps, dep) && !_toml_equal(base_deps[dep], head_deps[dep]) &&
            push!(msgs, "changed [deps] entry $(dep)")
    end

    for k in keys(head_compat)
        sk = String(k)
        if !haskey(base_compat, k)
            sk in new_dep_names || push!(msgs, "new [compat] for existing dep $(sk)")
            continue
        end
        b = string(base_compat[k])
        h = string(head_compat[k])
        b != h && push!(msgs, "[compat] loosening or change for $(sk) (strings differ)")
    end
    for k in keys(base_compat)
        haskey(head_compat, k) || push!(msgs, "removed [compat] for $(k)")
    end

    for section in ("sources", "workspace")
        b = get(base, section, nothing)
        h = get(head, section, nothing)
        !_toml_equal(b, h) && push!(msgs, "changed [$section]")
    end

    skip = Set(["deps", "compat", "sources", "workspace"])
    all_keys = union(Set(string(k) for k in keys(base)), Set(string(k) for k in keys(head)))
    for k in all_keys
        k in skip && continue
        bv = get(base, k, nothing)
        hv = get(head, k, nothing)
        !_toml_equal(bv, hv) && push!(msgs, "changed top-level key $k")
    end
    return msgs
end

function _ceilings_semantic_exempt!(root::AbstractString, base::AbstractString, policy::PolicyBundle)
    base_present, base_entry = load_ceilings_at_git_ref(root, base, policy)
    head_text = _read_working_text(root, CEILINGS_REL_PATH)
    head_entry = load_ceilings_string(head_text, policy, CEILINGS_REL_PATH)
    return !ceilings_increase_relative_to_base(head_entry, base_entry, base_present, policy)
end

function _project_toml_semantic_ok(
        root::AbstractString,
        base::AbstractString,
        relpath::AbstractString,
        st::Char,
        policy::PolicyBundle,
    )
    policy.project_toml_policy == "semantic" || return false
    if st == 'A'
        head = _parse_toml_policy!(_read_working_text(root, relpath), relpath)
        return isempty(project_toml_semantic_violations(Dict(), head))
    elseif st == 'D'
        return false
    end
    head = _parse_toml_policy!(_read_working_text(root, relpath), relpath)
    sha = git_resolve_commit_sha(root, base)
    if !git_tree_path_exists(root, sha, relpath)
        st == 'A' || throw(ParseError("missing Project.toml at diff base: $relpath"))
        return isempty(project_toml_semantic_violations(Dict(), head))
    end
    base_text = git_show_blob_at_commit(root, sha, relpath)
    base = _parse_toml_policy!(base_text, "$relpath@$base")
    return isempty(project_toml_semantic_violations(base, head))
end

function _protected_change_exempt(
        root::AbstractString,
        base::AbstractString,
        relpath::AbstractString,
        ev::DiffPathEvent,
        policy::PolicyBundle,
    )
    ev.status in ('R', 'C') && return false
    ev.status == 'D' && return false
    p = normalize_path(relpath)
    if p == CEILINGS_REL_PATH
        return _ceilings_semantic_exempt!(root, base, policy)
    end
    if _is_workspace_project_toml(p)
        return _project_toml_semantic_ok(root, base, p, ev.status, policy)
    end
    return false
end

function _handle_protected_event(
        root::AbstractString,
        base::AbstractString,
        ev::DiffPathEvent,
        policy::PolicyBundle,
    )
    out = Violation[]
    seen = Set{String}()
    glob_entry = _glob_entry_for_event(ev, policy)
    if glob_entry !== nothing
        use_glob_classifier = glob_entry.change_types !== nothing || ev.status == 'C'
        if use_glob_classifier
            for (p, word) in _filtered_glob_path_words(ev, glob_entry)
                p in seen && continue
                push!(seen, p)
                !_on_allows(glob_entry.change_types, word) && continue
                !_protected_change_exempt(root, base, p, ev, policy) || continue
                msg = "$(word) (reason: $(glob_entry.reason))"
                push!(out, _protected_paths_diag(p, msg, policy))
            end
            return out
        end
    end
    paths = ev.status in ('R', 'C') ? [ev.old_path, ev.path] : [ev.path]
    for p in paths
        p in seen && continue
        push!(seen, p)
        entry = _match_protected_glob_entry(p, policy)
        if entry !== nothing
            matched = true
            reason = entry.reason
        else
            matched, reason = _auto_classify_protected_path(p)
        end
        matched || continue
        if !_protected_change_exempt(root, base, p, ev, policy)
            word = _status_word(ev.status)
            msg = "$word (reason: $reason)"
            push!(out, _protected_paths_diag(p, msg, policy))
        end
    end
    return out
end

"""
    enforce_protected_paths(root, base, policy)

Diff-scoped enforcement only. Without a diff base the caller should not invoke this.
"""
function enforce_protected_paths(root::AbstractString, base::AbstractString, policy::PolicyBundle)
    get(policy.rules, PROTECTED_PATHS_RULE, nothing) === nothing && return Violation[]
    events = git_diff_path_events(root, base)
    out = Violation[]
    for ev in events
        append!(out, _handle_protected_event(root, base, ev, policy))
    end
    return out
end

const _PROTECTED_PATHS_EXPLAIN_DETAIL = """
Group: integrity. Level: forbid (no inline expects).

Runs only with `--diff <base>`. Reports nothing on a full-tree `check` without `--diff`.

Auto-protected paths include `$CONFIG_FILENAME`, the retired legacy config filename at repo root (rename required), `.agentrulelint/**`
(except `.agentrulelint/ceilings.toml` when the diff is monotonic non-increasing),
`.gitattributes`, `.gitmodules`, `.JETLSConfig.toml`, `Manifest*.toml`, `JuliaManifest.toml`,
`LocalPreferences.toml`, and every repo-relative `Project.toml`.

`project_toml_policy = "semantic"` (default) allows adding `[deps]` entries and `[compat]`
for newly added deps. Any change to `[sources]` or `[workspace]`, compat removal, or any
compat string change (loosening is any non-identical string; no semver reasoning in 0.1.0),
or any other top-level key change is a violation.

Declared `paths = [{ glob = "...", reason = "..." }]` under `[rules.protected-paths]` use
project-rule path-glob syntax; the reason appears in the message. An optional `on` array
restricts which change types each entry reports (`added`, `modified`, `deleted`, `renamed`,
`copied`); omit `on` to report every change type as today. Auto-protected paths ignore `on`.
Copy events differ from renames: a copy leaves the source in place, so only-destination match
is `added`, both match is `copied` on the destination only, and only-source match is silent.

Missing or unparsable TOML on either side of a compared change fails closed (exit 2).

Integrity level: `protected-paths`, `ceiling-ratchet`, and `scope-paths` must always use
`level = "forbid"` in config. Any other level is a ConfigError (exit 2). Rename or copy
of a protected path is never semantically exempt (including Project.toml and ceilings.toml).
"""

function protected_paths_explain_extra()
    return Dict{Symbol, String}(:detail => strip(_PROTECTED_PATHS_EXPLAIN_DETAIL))
end

const PROTECTED_PATHS_RULE_DEF = RuleDef(
    PROTECTED_PATHS_RULE,
    Origin.AGENTRULELINT,
    Level.FORBID,
    "Protect designated policy, lockfiles, and workflow paths from silent edits.",
    "Edit protected files, weaken compat, or rename paths to evade review.",
    Dict{Symbol, String}(),
    "protected_paths.jl",
    "test_protected_paths.jl",
    ("test/corpus/protected_paths_dep_add.toml",),
)
