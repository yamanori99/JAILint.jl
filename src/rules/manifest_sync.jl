# Built-in manifest-sync: pure TOML invariants for git-tracked Project/Manifest pairs.

const MANIFEST_SYNC_RULE = "manifest-sync"

const STANDARD_MANIFEST_BASENAMES = (
    "Manifest.toml",
    "JuliaManifest.toml",
)

const MANIFEST_V_RE = r"^Manifest-v(\d+)\.(\d+)\.toml$"

const RESOLVE_SECTION_KEYS = ("deps", "weakdeps", "compat", "sources", "workspace")

# Matches Pkg `manifest_format_for` minors for Julia versions this package supports
# (stdlib Pkg `manifest.jl`, `manifest_format_for`; see CONTRIBUTING).
const MANIFEST_FORMAT_ALLOWED_MINORS = (0, 1, 2)

const MANIFEST_TOP_LEVEL_BASE = (
    "julia_version",
    "project_hash",
    "manifest_format",
    "deps",
)

const MANIFEST_TOP_LEVEL_FROM_21 = ("registries",)

const MANIFEST_TOP_LEVEL_FROM_22 = (
    "environment_id",
    "environment_name",
)

struct ManifestProjectContext
    manifest_rel::String
    project_rel::String
    workspace_projects::Vector{String}
end

function _manifest_sync_spec(policy::PolicyBundle)
    return get(policy.rules, MANIFEST_SYNC_RULE, nothing)
end

function git_ls_tracked_files(root::AbstractString)
    root = abspath(String(root))
    _git_feature_not_repository(root, MANIFEST_SYNC_RULE)
    prefix = "$MANIFEST_SYNC_RULE requires git: git ls-files failed for $(root)"
    bytes = try
        read_git_cmd(root, "ls-files", "-z", "--end-of-options"; error_prefix = prefix)
    catch err
        err isa InterruptException && rethrow()
        err isa GitError && rethrow()
        throw(GitError("$prefix: $(format_error(err))"))
    end
    isempty(bytes) && return String[]
    parts = split(String(bytes), '\0'; keepempty = false)
    return sort(unique(normalize_path.(parts)))
end

function _is_manifest_basename(name::AbstractString)
    name in STANDARD_MANIFEST_BASENAMES && return true
    return match(MANIFEST_V_RE, name) !== nothing
end

function _read_worktree_text(root::AbstractString, relpath::AbstractString)
    ap = joinpath(root, relpath)
    !isfile(ap) && throw(ParseError("tracked file missing on disk: $relpath"))
    bytes = read(ap)
    isvalid(String, bytes) || throw(ParseError("file is not valid UTF-8: $relpath"))
    return String(bytes)
end

function _parse_toml_or_throw(text::AbstractString, label::AbstractString)
    try
        return TOML.parse(String(text))
    catch err
        err isa InterruptException && rethrow()
        throw(ParseError("TOML parse error in $label: $(format_error(err))"))
    end
end

function _toml_get_dict(raw, key::AbstractString, label::AbstractString)
    !haskey(raw, key) && return Dict{String, Any}()
    v = raw[key]
    v isa Dict || throw(ParseError("expected table for $key in $label"))
    return Dict{String, Any}(String(k) => v for (k, v) in v)
end

function _project_dep_tables(proj::Dict)
    out = Dict{String, String}()
    for key in ("deps", "weakdeps", "extras")
        tbl = _toml_get_dict(proj, key, "Project.toml")
        for (name, uuid) in tbl
            uuid isa AbstractString || continue
            out[name] = String(strip(uuid))
        end
    end
    return out
end

function _workspace_subprojects(proj_rel::AbstractString, proj::Dict)
    ws = _toml_get_dict(proj, "workspace", proj_rel)
    !haskey(ws, "projects") && return String[]
    raw = ws["projects"]
    raw isa AbstractVector || return String[]
    out = String[]
    base_dir = dirname(proj_rel)
    for p in raw
        p isa AbstractString || continue
        push!(out, normalize_path(joinpath(base_dir, String(p), "Project.toml")))
    end
    return out
end

function _custom_manifest_rel(proj::Dict, project_rel::AbstractString)
    !haskey(proj, "manifest") && return nothing
    m = proj["manifest"]
    m isa AbstractString || throw(ParseError("Project.toml manifest key must be a string ($project_rel)"))
    return normalize_path(joinpath(dirname(project_rel), String(m)))
end

function _tracked_manifests_adjacent(dir::AbstractString, tracked::Vector{String})
    d = normalize_path(dir)
    out = String[]
    for p in tracked
        normalize_path(dirname(p)) == d || continue
        _is_manifest_basename(basename(p)) || continue
        push!(out, p)
    end
    return out
end

function _claim_manifest_for_project!(
        manifest_to_project::Dict{String, String},
        conflicts::Vector{Tuple{String, String, String}},
        manifest_rel::String,
        project_rel::String,
    )
    prev = get(manifest_to_project, manifest_rel, nothing)
    if prev === nothing
        manifest_to_project[manifest_rel] = project_rel
        return nothing
    end
    prev == project_rel && return nothing
    push!(conflicts, (manifest_rel, prev, project_rel))
    return nothing
end

function _build_manifest_to_project_map(root::AbstractString, tracked::Vector{String})
    tracked_set = Set(tracked)
    manifest_to_project = Dict{String, String}()
    conflicts = Tuple{String, String, String}[]
    for proj_rel in tracked
        basename(proj_rel) == "Project.toml" || continue
        text = _read_worktree_text(root, proj_rel)
        proj = _parse_toml_or_throw(text, proj_rel)
        for m in _tracked_manifests_adjacent(dirname(proj_rel), tracked)
            _claim_manifest_for_project!(manifest_to_project, conflicts, m, proj_rel)
        end
        custom = _custom_manifest_rel(proj, proj_rel)
        if custom !== nothing && custom in tracked_set
            _claim_manifest_for_project!(manifest_to_project, conflicts, custom, proj_rel)
        end
    end
    return manifest_to_project, conflicts
end

function _report_manifest_project_conflicts!(
        diags::Vector{Violation},
        conflicts::Vector{Tuple{String, String, String}},
        level::Level.T,
        intent::String,
        do_not::String,
    )
    for (m, p1, p2) in sort(conflicts)
        _push_ms_violation!(
            diags,
            level,
            m,
            1,
            "tracked manifest '$m' is claimed by multiple Project.toml files ($p1, $p2)",
            intent,
            do_not,
        )
    end
    return nothing
end

function discover_manifest_project_pairs(root::AbstractString, tracked::Vector{String})
    tracked_set = Set(tracked)
    manifest_to_project, conflicts = _build_manifest_to_project_map(root, tracked)
    conflict_manifests =
        Set(String(m) for (m, _, _) in conflicts)
    pairs = ManifestProjectContext[]
    for (m, proj_rel) in manifest_to_project
        m in conflict_manifests && continue
        text = _read_worktree_text(root, proj_rel)
        proj = _parse_toml_or_throw(text, proj_rel)
        ws = filter(s -> s in tracked_set, _workspace_subprojects(proj_rel, proj))
        push!(pairs, ManifestProjectContext(m, proj_rel, ws))
    end
    sort!(pairs, by = ctx -> ctx.manifest_rel)
    orphans = String[]
    for m in tracked
        _is_manifest_basename(basename(m)) || continue
        haskey(manifest_to_project, m) && continue
        push!(orphans, m)
    end
    sort!(unique!(orphans))
    return pairs, orphans, conflicts
end

function _manifest_dep_record(pkg::AbstractString, entry, manifest_rel::AbstractString)
    label = "deps.$pkg in $manifest_rel"
    entry isa AbstractVector || throw(ParseError("$label must be an array of tables"))
    isempty(entry) && throw(ParseError("$label must not be empty"))
    rec = first(entry)
    rec isa Dict || throw(ParseError("$label entry must be a table"))
    return rec
end

function _manifest_dep_uuid!(rec::Dict, pkg::AbstractString, manifest_rel::AbstractString)
    label = "deps.$pkg in $manifest_rel"
    !haskey(rec, "uuid") && throw(ParseError("missing uuid in $label"))
    u = rec["uuid"]
    u isa AbstractString || throw(ParseError("uuid in $label must be a string"))
    return String(strip(u))
end

function _manifest_deps_map(man::Dict, manifest_rel::AbstractString)
    raw = get(man, "deps", Dict())
    raw isa Dict || throw(ParseError("manifest deps must be a table ($manifest_rel)"))
    names = Set{String}()
    uuids = Dict{String, String}()
    internal = Dict{String, Vector{String}}()
    paths = Dict{String, String}()
    repos = Dict{String, Dict{String, String}}()
    for (name, entry) in raw
        sn = String(name)
        rec = _manifest_dep_record(sn, entry, manifest_rel)
        push!(names, sn)
        uuids[sn] = _manifest_dep_uuid!(rec, sn, manifest_rel)
        if haskey(rec, "deps")
            d = rec["deps"]
            d isa AbstractVector && (internal[sn] = String[string(x) for x in d])
        end
        haskey(rec, "path") && (paths[sn] = String(rec["path"]))
        repo = Dict{String, String}()
        for k in ("repo-url", "repo-rev", "repo-subdir")
            haskey(rec, k) && (repo[k] = String(rec[k]))
        end
        !isempty(repo) && (repos[sn] = repo)
    end
    return names, uuids, internal, paths, repos
end

function _normalize_rel_path(base_dir::AbstractString, raw::AbstractString)
    s = replace(strip(String(raw)), '\\' => '/')
    isabspath(s) && return normalize_path(s)
    return normalize_path(joinpath(base_dir, s))
end

function _line_number_for_substring(source::AbstractString, needle::AbstractString; default_line = 1)
    pos = findfirst(needle, source)
    pos === nothing && return default_line
    return 1 + count('\n', source[1:((pos.start) - 1)])
end

function _push_ms_violation!(
        diags::Vector{Violation},
        level::Level.T,
        path::String,
        line::Int,
        msg::String,
        intent::String,
        do_not::String,
    )
    ln = max(line, 1)
    sp = Span(ln, 1, ln, 1)
    push!(
        diags,
        Violation(
            MANIFEST_SYNC_RULE,
            Origin.AGENTRULELINT,
            level,
            path,
            sp,
            ln,
            "",
            ExpectStatus.NONE,
            false,
            msg,
            intent,
            do_not,
        ),
    )
    return nothing
end

function _resolve_slice(proj::Dict)
    out = Dict{String, Any}()
    for k in RESOLVE_SECTION_KEYS
        haskey(proj, k) || continue
        out[k] = proj[k]
    end
    return out
end

function _line_for_dep(source::AbstractString, pkg::AbstractString)
    for n in ("$pkg =", "[deps.$pkg]", "\"$pkg\" =")
        ln = _line_number_for_substring(source, n, default_line = 0)
        ln > 0 && return ln
    end
    return 1
end

function _parse_manifest_format_version(raw)
    raw === nothing && return nothing
    s = raw isa AbstractString ? String(strip(raw)) : string(raw)
    return tryparse(VersionNumber, s)
end

function _report_orphan_tracked_manifests!(
        diags::Vector{Violation},
        orphans::Vector{String},
        level::Level.T,
        intent::String,
        do_not::String,
    )
    for m in orphans
        _push_ms_violation!(
            diags,
            level,
            m,
            1,
            "tracked manifest has no tracked Project.toml",
            intent,
            do_not,
        )
    end
    return nothing
end

function manifest_format_minor_allowed(v::VersionNumber)
    return v.major == 2 && v.minor in MANIFEST_FORMAT_ALLOWED_MINORS
end

function _manifest_format_from_dict(man::Dict)
    return _parse_manifest_format_version(get(man, "manifest_format", nothing))
end

function _allowed_manifest_top_level(fmt_minor::Int)
    out = String[string(k) for k in MANIFEST_TOP_LEVEL_BASE]
    fmt_minor >= 1 && append!(out, MANIFEST_TOP_LEVEL_FROM_21)
    fmt_minor >= 2 && append!(out, MANIFEST_TOP_LEVEL_FROM_22)
    return Set(out)
end

function _check_manifest_format!(
        diags::Vector{Violation},
        level::Level.T,
        manifest_rel::String,
        man::Dict,
        source::AbstractString,
        intent::String,
        do_not::String,
    )
    fmt = get(man, "manifest_format", nothing)
    if fmt === nothing
        _push_ms_violation!(diags, level, manifest_rel, 1, "missing manifest_format (fail-closed)", intent, do_not)
        return nothing
    end
    s = fmt isa AbstractString ? String(fmt) : string(fmt)
    ver = _parse_manifest_format_version(s)
    if ver !== nothing && manifest_format_minor_allowed(ver)
        return ver
    end
    ln = _line_number_for_substring(source, "manifest_format", default_line = 1)
    _push_ms_violation!(
        diags,
        level,
        manifest_rel,
        ln,
        "unsupported manifest_format '$s' (expected Pkg format 2.0, 2.1, or 2.2)",
        intent,
        do_not,
    )
    return nothing
end

function _check_manifest_top_level!(
        diags::Vector{Violation},
        level::Level.T,
        manifest_rel::String,
        man::Dict,
        fmt_minor::Int,
        source::AbstractString,
        intent::String,
        do_not::String,
    )
    allowed = _allowed_manifest_top_level(fmt_minor)
    for k in keys(man)
        sk = String(k)
        sk in allowed && continue
        ln = _line_number_for_substring(source, sk, default_line = 1)
        _push_ms_violation!(
            diags,
            level,
            manifest_rel,
            ln,
            "unexpected manifest top-level key '$sk' (not metadata for format 2.$fmt_minor)",
            intent,
            do_not,
        )
    end
    return nothing
end

function _check_manifest_version_filename!(
        diags::Vector{Violation},
        level::Level.T,
        manifest_rel::String,
        man::Dict,
        source::AbstractString,
        intent::String,
        do_not::String,
    )
    m = match(MANIFEST_V_RE, basename(manifest_rel))
    m === nothing && return nothing
    c1, c2 = m.captures
    c1 isa AbstractString || return nothing
    c2 isa AbstractString || return nothing
    major = parse(Int, c1)
    minor = parse(Int, c2)
    jv = get(man, "julia_version", nothing)
    if jv === nothing
        _push_ms_violation!(
            diags,
            level,
            manifest_rel,
            1,
            "Manifest-v filename requires julia_version",
            intent,
            do_not,
        )
        return nothing
    end
    jvs = jv isa AbstractString ? String(jv) : string(jv)
    jvn = tryparse(VersionNumber, jvs)
    if jvn === nothing
        _push_ms_violation!(diags, level, manifest_rel, 1, "invalid julia_version in manifest", intent, do_not)
        return nothing
    end
    (jvn.major, jvn.minor) == (major, minor) && return nothing
    ln = _line_number_for_substring(source, "julia_version", default_line = 1)
    _push_ms_violation!(
        diags,
        level,
        manifest_rel,
        ln,
        "Manifest-v$(major).$(minor) disagrees with julia_version $(jvs) at minor level",
        intent,
        do_not,
    )
    return nothing
end

function _collect_project_uuids(root::AbstractString, ctx::ManifestProjectContext)
    combined = Dict{String, String}()
    pkg_src = Dict{String, String}()
    pkg_text = Dict{String, String}()
    for rel in vcat([ctx.project_rel], ctx.workspace_projects)
        text = _read_worktree_text(root, rel)
        proj = _parse_toml_or_throw(text, rel)
        for (pkg, uuid) in _project_dep_tables(proj)
            combined[pkg] = uuid
            pkg_src[pkg] = rel
            pkg_text[pkg] = text
        end
    end
    return combined, pkg_src, pkg_text
end

function _check_project_deps_in_manifest!(
        diags::Vector{Violation},
        level::Level.T,
        ctx::ManifestProjectContext,
        wanted::Dict{String, String},
        pkg_src::Dict{String, String},
        pkg_text::Dict{String, String},
        names::Set{String},
        uuids::Dict{String, String},
        intent::String,
        do_not::String,
    )
    for (pkg, want_uuid) in sort(collect(wanted))
        rel = get(pkg_src, pkg, ctx.project_rel)
        text = get(pkg_text, pkg, "")
        if pkg ∉ names
            _push_ms_violation!(
                diags,
                level,
                rel,
                _line_for_dep(text, pkg),
                "dependency '$pkg' missing from manifest $(ctx.manifest_rel)",
                intent,
                do_not,
            )
            continue
        end
        got = get(uuids, pkg, "")
        got == want_uuid && continue
        _push_ms_violation!(
            diags,
            level,
            rel,
            _line_for_dep(text, pkg),
            "dependency '$pkg' UUID mismatch: project $(want_uuid) vs manifest $(got)",
            intent,
            do_not,
        )
    end
    return nothing
end

function _check_manifest_internal_closure!(
        diags::Vector{Violation},
        level::Level.T,
        manifest_rel::String,
        names::Set{String},
        internal::Dict{String, Vector{String}},
        intent::String,
        do_not::String,
    )
    for (pkg, refs) in sort(collect(internal))
        for ref in refs
            ref in names && continue
            _push_ms_violation!(
                diags,
                level,
                manifest_rel,
                1,
                "manifest entry '$pkg' references missing dependency '$ref'",
                intent,
                do_not,
            )
        end
    end
    return nothing
end

function _check_uuid_uniqueness!(
        diags::Vector{Violation},
        level::Level.T,
        manifest_rel::String,
        uuids::Dict{String, String},
        intent::String,
        do_not::String,
    )
    inv = Dict{String, String}()
    for (pkg, uuid) in uuids
        other = get(inv, uuid, nothing)
        if other !== nothing
            _push_ms_violation!(
                diags,
                level,
                manifest_rel,
                1,
                "duplicate manifest UUID $uuid ($other and $pkg)",
                intent,
                do_not,
            )
            continue
        end
        inv[uuid] = pkg
    end
    return nothing
end

function _project_sources_entry(pkg::AbstractString, src, project_rel::AbstractString)
    src isa Dict || throw(ParseError("sources entry for '$pkg' in $project_rel must be a table"))
    return Dict{String, Any}(String(k) => v for (k, v) in src)
end

function _check_sources_warn!(
        diags::Vector{Violation},
        ctx::ManifestProjectContext,
        proj::Dict,
        project_text::AbstractString,
        man_paths::Dict{String, String},
        man_repos::Dict{String, Dict{String, String}},
        intent::String,
        do_not::String,
    )
    sources = _toml_get_dict(proj, "sources", ctx.project_rel)
    base = dirname(ctx.project_rel)
    for (pkg, src) in sort(collect(sources))
        sd = _project_sources_entry(pkg, src, ctx.project_rel)
        if haskey(sd, "path")
            want = _normalize_rel_path(base, String(sd["path"]))
            got = get(man_paths, pkg, "")
            got = got == "" ? "" : _normalize_rel_path(base, got)
            want == got && continue
            _push_ms_violation!(
                diags,
                Level.WARN,
                ctx.project_rel,
                _line_for_dep(project_text, pkg),
                "sources path for '$pkg' disagrees with manifest path",
                intent,
                do_not,
            )
            continue
        end
        haskey(sd, "url") || continue
        repo = get(man_repos, pkg, Dict{String, String}())
        url_ok = get(repo, "repo-url", "") == String(sd["url"])
        rev_ok = !haskey(sd, "rev") || get(repo, "repo-rev", "") == String(sd["rev"])
        sub_ok = !haskey(sd, "subdir") || get(repo, "repo-subdir", "") == String(sd["subdir"])
        url_ok && rev_ok && sub_ok && continue
        _push_ms_violation!(
            diags,
            Level.WARN,
            ctx.project_rel,
            _line_for_dep(project_text, pkg),
            "sources entry for '$pkg' disagrees with manifest repo metadata",
            intent,
            do_not,
        )
    end
    return nothing
end

function _extension_triggers(proj::Dict)
    !haskey(proj, "extensions") && return String[]
    ext = proj["extensions"]
    ext isa Dict || return String[]
    out = String[]
    for (_, v) in ext
        if v isa AbstractString
            push!(out, String(v))
        elseif v isa AbstractVector
            for x in v
                x isa AbstractString && push!(out, String(x))
            end
        end
    end
    return out
end

function _check_extensions!(
        diags::Vector{Violation},
        level::Level.T,
        project_rel::String,
        proj::Dict,
        project_text::AbstractString,
        intent::String,
        do_not::String,
    )
    declared = Set(keys(_toml_get_dict(proj, "deps", project_rel)))
    for w in keys(_toml_get_dict(proj, "weakdeps", project_rel))
        push!(declared, w)
    end
    for trig in _extension_triggers(proj)
        trig in declared && continue
        _push_ms_violation!(
            diags,
            level,
            project_rel,
            _line_for_dep(project_text, trig),
            "extension trigger '$trig' is not declared in [deps] or [weakdeps]",
            intent,
            do_not,
        )
    end
    return nothing
end

function _warn_subproject_manifests!(
        diags::Vector{Violation},
        ctx::ManifestProjectContext,
        tracked_set::Set{String},
        intent::String,
        do_not::String,
    )
    for sub in ctx.workspace_projects
        dir = dirname(sub)
        for cand in ("Manifest.toml", "JuliaManifest.toml")
            rel = normalize_path(joinpath(dir, cand))
            rel in tracked_set || continue
            _push_ms_violation!(
                diags,
                Level.WARN,
                sub,
                1,
                "workspace subproject has its own tracked manifest ($rel)",
                intent,
                do_not,
            )
        end
    end
    return nothing
end

function _manifest_project_hash(text::AbstractString, label::AbstractString)
    man = _parse_toml_or_throw(text, label)
    h = get(man, "project_hash", nothing)
    h isa AbstractString || return nothing
    return String(h)
end

function _check_project_hash_diff!(
        diags::Vector{Violation},
        level::Level.T,
        root::AbstractString,
        diff_base::AbstractString,
        ctx::ManifestProjectContext,
        intent::String,
        do_not::String,
    )
    proj_now_text = _read_worktree_text(root, ctx.project_rel)
    proj_now = _parse_toml_or_throw(proj_now_text, ctx.project_rel)
    sha = git_resolve_commit_sha(root, diff_base)
    git_tree_path_exists(root, sha, ctx.project_rel) || return nothing
    proj_base_text = git_show_blob_at_commit(root, sha, ctx.project_rel)
    proj_base = _parse_toml_or_throw(proj_base_text, "$(ctx.project_rel)@$diff_base")
    _resolve_slice(proj_now) == _resolve_slice(proj_base) && return nothing
    man_text = _read_worktree_text(root, ctx.manifest_rel)
    now_hash = _manifest_project_hash(man_text, ctx.manifest_rel)
    now_hash === nothing && return nothing
    git_tree_path_exists(root, sha, ctx.manifest_rel) || return nothing
    base_text = git_show_blob_at_commit(root, sha, ctx.manifest_rel)
    base_hash = _manifest_project_hash(base_text, "$(ctx.manifest_rel)@$sha")
    base_hash === nothing && return nothing
    now_hash == base_hash || return nothing
    ln = _line_number_for_substring(proj_now_text, "julia =", default_line = 1)
    ln == 1 && (ln = _line_number_for_substring(proj_now_text, "[deps]", default_line = 1))
    _push_ms_violation!(
        diags,
        level,
        ctx.project_rel,
        ln,
        "resolve sections in $(ctx.project_rel) changed vs $(diff_base) but project_hash is unchanged",
        intent,
        do_not,
    )
    return nothing
end

function _manifest_sync_in_scope(paths::Vector{String}, diff_base)
    diff_base !== nothing && return true
    isempty(paths) && return true
    for p in paths
        bn = basename(normalize_path(p))
        bn == "Project.toml" && return true
        _is_manifest_basename(bn) && return true
    end
    return false
end

function run_manifest_sync(
        root::AbstractString,
        policy::PolicyBundle;
        diff_base = nothing,
        paths = String[],
    )
    spec = _manifest_sync_spec(policy)
    spec === nothing && return Violation[]
    spec.level == Level.ALLOW && return Violation[]
    _manifest_sync_in_scope(paths, diff_base) || return Violation[]
    level = spec.level
    intent = spec.intent
    do_not = spec.do_not
    tracked = git_ls_tracked_files(root)
    tracked_set = Set(tracked)
    pairs, orphans, conflicts = discover_manifest_project_pairs(root, tracked)
    diags = Violation[]
    _report_manifest_project_conflicts!(diags, conflicts, level, intent, do_not)
    _report_orphan_tracked_manifests!(diags, orphans, level, intent, do_not)
    for ctx in pairs
        _audit_manifest_pair!(diags, root, ctx, tracked_set, level, intent, do_not, diff_base)
    end
    return diags
end

function _audit_manifest_pair!(
        diags::Vector{Violation},
        root::AbstractString,
        ctx::ManifestProjectContext,
        tracked_set::Set{String},
        level::Level.T,
        intent::String,
        do_not::String,
        diff_base,
    )
    man_text = _read_worktree_text(root, ctx.manifest_rel)
    man = _parse_toml_or_throw(man_text, ctx.manifest_rel)
    fmt_ver = _check_manifest_format!(diags, level, ctx.manifest_rel, man, man_text, intent, do_not)
    if fmt_ver !== nothing
        _check_manifest_top_level!(
            diags,
            level,
            ctx.manifest_rel,
            man,
            Int(fmt_ver.minor),
            man_text,
            intent,
            do_not,
        )
    end
    _check_manifest_version_filename!(diags, level, ctx.manifest_rel, man, man_text, intent, do_not)
    names, uuids, internal, paths, repos = _manifest_deps_map(man, ctx.manifest_rel)
    _check_manifest_internal_closure!(diags, level, ctx.manifest_rel, names, internal, intent, do_not)
    _check_uuid_uniqueness!(diags, level, ctx.manifest_rel, uuids, intent, do_not)
    wanted, pkg_src, pkg_text = _collect_project_uuids(root, ctx)
    _check_project_deps_in_manifest!(
        diags,
        level,
        ctx,
        wanted,
        pkg_src,
        pkg_text,
        names,
        uuids,
        intent,
        do_not,
    )
    proj_text = _read_worktree_text(root, ctx.project_rel)
    proj = _parse_toml_or_throw(proj_text, ctx.project_rel)
    _check_sources_warn!(diags, ctx, proj, proj_text, paths, repos, intent, do_not)
    for rel in vcat([ctx.project_rel], ctx.workspace_projects)
        sub_text = _read_worktree_text(root, rel)
        sub_proj = _parse_toml_or_throw(sub_text, rel)
        _check_extensions!(diags, level, rel, sub_proj, sub_text, intent, do_not)
    end
    _warn_subproject_manifests!(diags, ctx, tracked_set, intent, do_not)
    diff_base !== nothing && _check_project_hash_diff!(diags, level, root, diff_base, ctx, intent, do_not)
    return nothing
end

const _MANIFEST_SYNC_EXPLAIN_ANCHOR = """
Project table key or manifest header field (e.g. [deps], project_hash).
"""

const _MANIFEST_SYNC_EXPLAIN_DETAIL = """
Group: integrity. Pure TOML against git-tracked Project.toml / Manifest.toml pairs
(Manifest.toml, Manifest-vX.Y.toml, JuliaManifest.toml, and Project.toml `manifest` paths).
Untracked working-tree manifests are out of scope.

deny: project [deps] (including workspace subprojects), [weakdeps], and [extras] UUIDs
exist in the paired manifest; manifest internal deps closure; UUID uniqueness;
Manifest-vX.Y minor version vs julia_version; in --diff mode, resolve sections
([deps], [weakdeps], [compat], [sources], [workspace]) changed without project_hash
update (hash is never recomputed); [extensions] triggers declared; manifest_format must be Pkg
format 2.0, 2.1, or 2.2 (major 2 only); unknown top-level manifest keys fail closed.

warn: [sources] vs manifest repo/path metadata (normalized paths); tracked manifest
under a workspace subproject directory.

Out of scope: Pkg resolvability, registry presence, git-tree-sha1 verification,
[compat] semver satisfaction, Artifacts.toml, Preferences.

Unparseable TOML is a fail-closed error (exit 2).
"""

function manifest_sync_explain_extra()
    return Dict{Symbol, String}(
        :anchor_line => strip(_MANIFEST_SYNC_EXPLAIN_ANCHOR),
        :detail => strip(_MANIFEST_SYNC_EXPLAIN_DETAIL),
    )
end

const MANIFEST_SYNC_RULE_DEF = RuleDef(
    MANIFEST_SYNC_RULE,
    Origin.AGENTRULELINT,
    Level.DENY,
    "Tracked Manifest.toml files must stay consistent with Project.toml (integrity).",
    "Edit [deps] or other resolve sections without updating the tracked manifest.",
    Dict{Symbol, String}(:group => "integrity"),
    "manifest_sync.jl",
    "test_manifest_sync.jl",
    ("test/corpus/manifest_sync/positive/Project.toml.fixture",),
)
