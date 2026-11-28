# Ceiling ratchet: monotonic per-(rule, path) violation and expect counts (fail-closed).

const CEILING_VIOLATIONS_PREFIX = "violations"
const CEILING_EXPECTS_PREFIX = "expects"
# CEILING_RATCHET_RULE is defined in config.jl

function _ceilings_path(root::AbstractString)
    return joinpath(abspath(root), CEILINGS_REL)
end

function _known_rule_ids(policy::PolicyBundle)
    out = Set{String}()
    for (_, r) in policy.rules
        push!(out, r.id)
    end
    for pr in policy.project_rules
        push!(out, project_rule_id(pr))
    end
    return out
end

function _parse_ceiling_table(raw, label::String)
    raw isa Dict || throw(ConfigError("malformed ceilings: $label must be a table"))
    outer = Dict{String, Dict{String, Int}}()
    for (rid, paths) in raw
        sid = String(rid)
        paths isa Dict || throw(ConfigError("malformed ceilings: $label.$sid must be a table"))
        inner = Dict{String, Int}()
        for (p, c) in paths
            sp = normalize_path(String(p))
            c isa Integer || throw(ConfigError("malformed ceilings: $label.$sid.\"$sp\" must be an integer"))
            ci = Int(c)
            ci < 0 && throw(ConfigError("malformed ceilings: $label.$sid.\"$sp\" must be non-negative"))
            inner[sp] = ci
        end
        outer[sid] = inner
    end
    return outer
end

function _load_ceilings_parsed(raw::Dict, policy::PolicyBundle)
    known = _known_rule_ids(policy)
    viol = Dict{String, Dict{String, Int}}()
    exp = Dict{String, Dict{String, Int}}()
    for (k, v) in raw
        sk = String(k)
        if sk == CEILING_VIOLATIONS_PREFIX
            viol = _parse_ceiling_table(v, "violations")
            continue
        elseif sk == CEILING_EXPECTS_PREFIX
            exp = _parse_ceiling_table(v, "expects")
            continue
        end
        throw(ConfigError("malformed ceilings: unknown top-level key '$sk'"))
    end
    for rid in keys(viol)
        rid in known || throw(ConfigError("unknown rule id in ceilings violations: $rid"))
    end
    for rid in keys(exp)
        rid in known || throw(ConfigError("unknown rule id in ceilings expects: $rid"))
    end
    return CeilingEntry(viol, exp)
end

"""
    load_ceilings(root, policy)

Load and validate `.agentrulelint/ceilings.toml` from the working tree.
Unknown top-level keys, unknown rule ids, or malformed counts are `ConfigError` (exit 2).
When the file is missing, returns empty ceilings (no enforcement slack).
"""
function load_ceilings(root::AbstractString, policy::PolicyBundle)
    path = _ceilings_path(root)
    !isfile(path) && return CeilingEntry(Dict(), Dict())
    raw = load_toml_file(path)
    return _load_ceilings_parsed(raw, policy)
end

function load_ceilings_string(toml_string::String, policy::PolicyBundle, path_label::String)
    raw = load_toml_string(toml_string, path_label)
    return _load_ceilings_parsed(raw, policy)
end

"""
    load_ceilings_at_git_ref(root, ref, policy)

Return `(present, CeilingEntry)` for `.agentrulelint/ceilings.toml` at `ref`.
Resolves `ref` to a commit, probes the tree with `git ls-tree`, then reads the blob.
Git or TOML errors are fail-closed (`GitError` / `ConfigError` / `ParseError`).
"""
function load_ceilings_at_git_ref(root::AbstractString, ref::AbstractString, policy::PolicyBundle)
    root = abspath(String(root))
    sha = git_resolve_commit_sha(root, ref)
    git_tree_path_exists(root, sha, CEILINGS_REL) || return false, CeilingEntry(Dict(), Dict())
    text = git_show_blob_at_commit(root, sha, CEILINGS_REL)
    label = "$(CEILINGS_REL)@$(ref)"
    return true, load_ceilings_string(text, policy, label)
end

function count_violation_hits(diags::Vector{Violation})
    counts = Dict{String, Dict{String, Int}}()
    for d in diags
        is_violation_hit(d) || continue
        d.rule_id == CEILING_RATCHET_RULE && continue
        counts[d.rule_id] = get(counts, d.rule_id, Dict{String, Int}())
        counts[d.rule_id][d.path] = get(counts[d.rule_id], d.path, 0) + 1
    end
    return counts
end

function count_expect_lines(contexts::Vector{FileContext})
    counts = Dict{String, Dict{String, Int}}()
    for fc in contexts
        for ex in fc.expects
            ref = strip(ex.rule_ref)
            isempty(ref) && continue
            counts[ref] = get(counts, ref, Dict{String, Int}())
            counts[ref][fc.parsed.path] = get(counts[ref], fc.parsed.path, 0) + 1
        end
    end
    return counts
end

function _in_ratchet_scope(path::String, scope_paths::Union{Nothing, Set{String}})
    scope_paths === nothing && return true
    return path in scope_paths
end

function _ceiling_ratchet_diag(path::String, _rule_id::String, message::String, policy::PolicyBundle)
    spec = get(policy.rules, CEILING_RATCHET_RULE, nothing)
    spec === nothing &&
        throw(InternalError("built-in rule $CEILING_RATCHET_RULE missing from policy"))
    return Violation(
        CEILING_RATCHET_RULE,
        Origin.AGENTRULELINT,
        Level.FORBID,
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

function enforce_ceiling_ratchet(
        violation_counts::Dict{String, Dict{String, Int}},
        expect_counts::Dict{String, Dict{String, Int}},
        ceilings::CeilingEntry,
        policy::PolicyBundle;
        scope_paths = nothing,
    )
    out = Violation[]
    seen_viol = Set{Tuple{String, String}}()
    seen_exp = Set{Tuple{String, String}}()

    for (rid, paths) in violation_counts
        for (path, actual) in paths
            _in_ratchet_scope(path, scope_paths) || continue
            ceiling = get(get(ceilings.violations, rid, Dict{String, Int}()), path, 0)
            key = (rid, path)
            key in seen_viol && continue
            push!(seen_viol, key)
            if actual > ceiling
                msg = "violation count increased for $rid at $path: actual=$actual ceiling=$ceiling"
                push!(out, _ceiling_ratchet_diag(path, rid, msg, policy))
            end
        end
    end
    for (rid, paths) in ceilings.violations
        for (path, ceiling) in paths
            _in_ratchet_scope(path, scope_paths) || continue
            key = (rid, path)
            actual = get(get(violation_counts, rid, Dict{String, Int}()), path, 0)
            if actual > ceiling
                key in seen_viol && continue
                msg = "violation count increased for $rid at $path: actual=$actual ceiling=$ceiling"
                push!(out, _ceiling_ratchet_diag(path, rid, msg, policy))
            elseif actual < ceiling
                msg =
                    "violation count decreased for $rid at $path: actual=$actual ceiling=$ceiling (run agentrulelint ratchet --write)"
                push!(out, _ceiling_ratchet_diag(path, rid, msg, policy))
            end
        end
    end

    for (rid, paths) in expect_counts
        for (path, actual) in paths
            _in_ratchet_scope(path, scope_paths) || continue
            ceiling = get(get(ceilings.expects, rid, Dict{String, Int}()), path, 0)
            key = (rid, path)
            key in seen_exp && continue
            push!(seen_exp, key)
            if actual > ceiling
                msg = "expect count increased for $rid at $path: actual=$actual ceiling=$ceiling"
                push!(out, _ceiling_ratchet_diag(path, rid, msg, policy))
            end
        end
    end
    for (rid, paths) in ceilings.expects
        for (path, ceiling) in paths
            _in_ratchet_scope(path, scope_paths) || continue
            actual = get(get(expect_counts, rid, Dict{String, Int}()), path, 0)
            if actual > ceiling
                msg = "expect count increased for $rid at $path: actual=$actual ceiling=$ceiling"
                push!(out, _ceiling_ratchet_diag(path, rid, msg, policy))
            elseif actual < ceiling
                msg =
                    "expect count decreased for $rid at $path: actual=$actual ceiling=$ceiling (run agentrulelint ratchet --write)"
                push!(out, _ceiling_ratchet_diag(path, rid, msg, policy))
            end
        end
    end
    return out
end

function _compare_ceiling_tables(
        working::Dict{String, Dict{String, Int}},
        base::Dict{String, Dict{String, Int}},
        kind::String,
        policy::PolicyBundle,
    )
    out = Violation[]
    diag_path = ".agentrulelint/ceilings.toml"
    for (rid, wpaths) in working
        for (path, wval) in wpaths
            bval = get(get(base, rid, Dict{String, Int}()), path, nothing)
            if bval === nothing
                wval > 0 || continue
                msg = "ceilings.toml new $kind ceiling for $rid at $path: working=$wval (base had no entry)"
                push!(out, _ceiling_ratchet_diag(diag_path, rid, msg, policy))
            elseif wval > bval
                msg = "ceilings.toml $kind ceiling raised for $rid at $path: base=$bval working=$wval"
                push!(out, _ceiling_ratchet_diag(diag_path, rid, msg, policy))
            end
        end
    end
    for (rid, bpaths) in base
        for (path, bval) in bpaths
            haskey(get(working, rid, Dict{String, Int}()), path) && continue
            bval > 0 || continue
            msg = "ceilings.toml $kind ceiling raised for $rid at $path: base=$bval working=0 (entry removed)"
            push!(out, _ceiling_ratchet_diag(diag_path, rid, msg, policy))
        end
    end
    return out
end

"""
Return `true` when `working` ceilings increase relative to `base` (not monotonic non-increasing).
Used by `protected-paths` to exempt `.agentrulelint/ceilings.toml` when counts only go down.
"""
function ceilings_increase_relative_to_base(
        working::CeilingEntry,
        base::CeilingEntry,
        base_present::Bool,
        policy::PolicyBundle,
    )
    diags = enforce_ceilings_vs_git_base(working, base, base_present, true, policy)
    return !isempty(diags)
end

function enforce_ceilings_vs_git_base(
        working::CeilingEntry,
        base::CeilingEntry,
        base_present::Bool,
        working_present::Bool,
        policy::PolicyBundle,
    )
    out = Violation[]
    if base_present && !working_present
        msg = "ceilings.toml removed relative to diff base"
        push!(out, _ceiling_ratchet_diag(".agentrulelint/ceilings.toml", CEILING_RATCHET_RULE, msg, policy))
        return out
    end
    working_present || return out
    append!(out, _compare_ceiling_tables(working.violations, base.violations, "violation", policy))
    append!(out, _compare_ceiling_tables(working.expects, base.expects, "expect", policy))
    return out
end

function _deep_copy_counts(d::Dict{String, Dict{String, Int}})
    out = Dict{String, Dict{String, Int}}()
    for (k, v) in d
        out[k] = Dict{String, Int}(p => c for (p, c) in v)
    end
    return out
end

function merge_ceiling_entry(
        base::CeilingEntry,
        overlay_viol::Dict{String, Dict{String, Int}},
        overlay_exp::Dict{String, Dict{String, Int}},
        scope_paths::Set{String},
    )
    viol = _deep_copy_counts(base.violations)
    exp = _deep_copy_counts(base.expects)
    for (rid, paths) in overlay_viol
        for (p, c) in paths
            p in scope_paths || continue
            viol[rid] = get(viol, rid, Dict{String, Int}())
            viol[rid][p] = c
        end
    end
    for (rid, paths) in overlay_exp
        for (p, c) in paths
            p in scope_paths || continue
            exp[rid] = get(exp, rid, Dict{String, Int}())
            exp[rid][p] = c
        end
    end
    return CeilingEntry(viol, exp)
end

function _ceilings_toml_dict(entry::CeilingEntry)
    d = Dict{String, Any}()
    !isempty(entry.violations) && (d[CEILING_VIOLATIONS_PREFIX] = entry.violations)
    !isempty(entry.expects) && (d[CEILING_EXPECTS_PREFIX] = entry.expects)
    return d
end

function write_ceilings_toml!(path::AbstractString, entry::CeilingEntry)
    io = IOBuffer()
    println(io, "# Updated via agentrulelint ratchet --write")
    println(io, "# Monotonic non-increasing semantics apply on manual review.")
    body = _ceilings_toml_dict(entry)
    if !isempty(body)
        println(io)
        TOML.print(io, body)
    end
    write(path, String(take!(io)))
    return path
end
