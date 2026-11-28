const TEST_INTEGRITY_RULE = "test-integrity"
const RUNTESTS_REL = "test/runtests.jl"

const _SKIP_BROKEN_MACROS = ("test_skip", "test_broken")
const _BROAD_THROW_TYPES = ("Exception", "ErrorException")

struct RuntestsEntry
    kind::Symbol
    key::String
    line::Int
    byte_start::Int
    byte_end::Int
end

struct ApproxTolSnapshot
    testset::String
    arg_sig::String
    within_testset::Int
    pairing_key::String
    line::Int
    byte_start::Int
    byte_end::Int
    atol::Union{Nothing, Float64}
    rtol::Union{Nothing, Float64}
end

function _test_integrity_level(policy::PolicyBundle)
    rule = get(policy.rules, TEST_INTEGRITY_RULE, nothing)
    rule === nothing && return Level.ALLOW
    return rule.level == Level.ALLOW ? Level.ALLOW : rule.level
end

function _test_integrity_spec(policy::PolicyBundle)
    rule = get(policy.rules, TEST_INTEGRITY_RULE, nothing)
    rule === nothing && return ("", "")
    return rule.intent, rule.do_not
end

function _under_test_tree(path::AbstractString)
    p = normalize_path(path)
    return startswith(p, "test/") || p == RUNTESTS_REL
end

function _push_test_integrity!(
        diags::Vector{Violation},
        policy::PolicyBundle,
        path::String,
        source::AbstractString,
        byte_start::Int,
        byte_end::Int,
        msg::String,
    )
    lvl = _test_integrity_level(policy)
    lvl == Level.ALLOW && return
    intent, do_not = _test_integrity_spec(policy)
    sp = span_from_byte_range(source, byte_start, byte_end)
    push!(
        diags,
        Violation(
            TEST_INTEGRITY_RULE,
            Origin.AGENTRULELINT,
            lvl,
            path,
            sp,
            sp.start_line,
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

function _macro_name_text(node::SyntaxTree, src::AbstractString, pos::Int)
    syntax_kind(node) == KMacroName || return ""
    for (c, cp) in _child_positions(node, pos)[1]
        syntax_kind(c) == KIdentifier || continue
        return _node_text_trim(c, src, cp)
    end
    return ""
end

function _ti_macrocall_name(node::SyntaxTree, src::AbstractString, pos::Int)
    syntax_kind(node) == KMacrocall || return ""
    for (c, cp) in _child_positions(node, pos)[1]
        syntax_kind(c) == KMacroName || continue
        return _macro_name_text(c, src, cp)
    end
    return ""
end

function _macrocall_args(node::SyntaxTree, pos::Int)
    syntax_kind(node) == KMacrocall || return SyntaxTree[], Int[]
    args = SyntaxTree[]
    argpos = Int[]
    for (c, cp) in _child_positions(node, pos)[1]
        syntax_kind(c) == KMacroName && continue
        syntax_is_trivia(c) && continue
        push!(args, c)
        push!(argpos, cp)
    end
    return args, argpos
end

function _qualified_ident_tail(node::SyntaxTree, src::AbstractString, pos::Int)
    if syntax_kind(node) == KIdentifier
        return _node_text_trim(node, src, pos)
    elseif syntax_kind(node) == KDot
        last = ""
        for (c, cp) in _child_positions(node, pos)[1]
            syntax_is_trivia(c) && continue
            if syntax_kind(c) == KIdentifier
                last = _node_text_trim(c, src, cp)
            elseif syntax_kind(c) == KDot
                continue
            end
        end
        return last
    end
    return ""
end

function _exception_type_too_broad(node::SyntaxTree, src::AbstractString, pos::Int)
    tail = _qualified_ident_tail(node, src, pos)
    return tail in _BROAD_THROW_TYPES
end

function _call_callee_ident(node::SyntaxTree, src::AbstractString, pos::Int)
    syntax_kind(node) == KCall || return ""
    kids, _ = _child_positions(node, pos)
    for (c, cp) in kids
        syntax_is_trivia(c) && continue
        syntax_kind(c) == KIdentifier && return _node_text_trim(c, src, cp)
        syntax_kind(c) == KDot && return _qualified_ident_tail(c, src, cp)
        break
    end
    return ""
end

function _is_exit_call(node::SyntaxTree, src::AbstractString, pos::Int)
    syntax_kind(node) != KCall && return false
    callee = _call_callee_ident(node, src, pos)
    return callee == "exit"
end

function _folded_string_arg(node::SyntaxTree, src::AbstractString, pos::Int)
    v = _fold_atom(node, src, pos, 0, FoldBudget())
    return v
end

function _top_level_include_paths(tree::SyntaxTree, src::AbstractString)
    paths = String[]
    for (node, pos) in _toplevel_stmt_nodes(tree)
        syntax_kind(node) == KCall || continue
        _call_callee_ident(node, src, pos) == "include" || continue
        kids, _ = _child_positions(node, pos)
        lit = nothing
        litp = 0
        seen_callee = false
        for (c, cp) in kids
            syntax_is_trivia(c) && continue
            if !seen_callee
                seen_callee = true
                continue
            end
            lit = c
            litp = cp
            break
        end
        lit === nothing && continue
        path = _folded_string_arg(lit, src, litp)
        path === nothing && continue
        push!(paths, path)
    end
    return paths
end

function _walk_tree_first_macro(node::SyntaxTree, pos::Int, src::AbstractString, want::String)
    if syntax_kind(node) == KMacrocall && _ti_macrocall_name(node, src, pos) == want
        return (line_number_at_byte(src, pos), pos, pos + syntax_span(node) - 1)
    end
    for (c, cp) in _child_positions(node, pos)[1]
        syntax_is_trivia(c) && continue
        hit = _walk_tree_first_macro(c, cp, src, want)
        hit[1] > 0 && return hit
    end
    return (0, 0, 0)
end

function _first_macro_line(tree::SyntaxTree, src::AbstractString, name::AbstractString)
    return _walk_tree_first_macro(tree, 1, src, String(name))
end

function _runtests_entries(tree::SyntaxTree, src::AbstractString)::Vector{RuntestsEntry}
    out = RuntestsEntry[]
    for (node, pos) in _toplevel_stmt_nodes(tree)
        if syntax_kind(node) == KCall && _call_callee_ident(node, src, pos) == "include"
            kids, _ = _child_positions(node, pos)
            lit = nothing
            litp = 0
            seen_callee = false
            for (c, cp) in kids
                syntax_is_trivia(c) && continue
                if !seen_callee
                    seen_callee = true
                    continue
                end
                lit = c
                litp = cp
                break
            end
            lit === nothing && continue
            path = _folded_string_arg(lit, src, litp)
            path === nothing && continue
            sp = span_from_byte_range(src, pos, pos + syntax_span(node) - 1)
            push!(
                out,
                RuntestsEntry(:include, path, sp.start_line, pos, pos + syntax_span(node) - 1),
            )
        elseif syntax_kind(node) == KMacrocall && _ti_macrocall_name(node, src, pos) == "testset"
            args, argpos = _macrocall_args(node, pos)
            isempty(args) && continue
            name = _folded_string_arg(args[1], src, argpos[1])
            name === nothing && continue
            sp = span_from_byte_range(src, pos, pos + syntax_span(node) - 1)
            push!(
                out,
                RuntestsEntry(:testset, name, sp.start_line, pos, pos + syntax_span(node) - 1),
            )
        end
    end
    return out
end

function _walk_count_test_macros!(
        counts::Dict{String, Int},
        node::SyntaxTree,
        pos::Int,
        src::AbstractString,
        names::Tuple{Vararg{String}},
    )
    if syntax_kind(node) == KMacrocall
        m = _ti_macrocall_name(node, src, pos)
        if m in names
            counts[m] = get(counts, m, 0) + 1
        end
    end
    for (c, cp) in _child_positions(node, pos)[1]
        syntax_is_trivia(c) || _walk_count_test_macros!(counts, c, cp, src, names)
    end
    return nothing
end

function _count_macro_ops(tree::SyntaxTree, src::AbstractString, names::Tuple{Vararg{String}})
    counts = Dict{String, Int}()
    for n in names
        counts[n] = 0
    end
    _walk_count_test_macros!(counts, tree, 1, src, names)
    return counts
end

function _walk_test_integrity_node!(
        diags::Vector{Violation},
        policy::PolicyBundle,
        path::String,
        source::AbstractString,
        consts::Dict{String, TestFoldConst},
        node::SyntaxTree,
        pos::Int,
        track_exit::Bool,
    )
    if syntax_kind(node) == KMacrocall
        mname = _ti_macrocall_name(node, source, pos)
        if mname == "test"
            args, argpos = _macrocall_args(node, pos)
            if !isempty(args)
                cond = args[1]
                cp = argpos[1]
                fold_res = test_condition_fold_result(cond, source, cp, consts)
                if fold_res == TEST_FOLD_TRIVIAL
                    _push_test_integrity!(
                        diags,
                        policy,
                        path,
                        source,
                        pos,
                        pos + syntax_span(node) - 1,
                        "@test condition is trivially true after constant folding",
                    )
                elseif fold_res == TEST_FOLD_BUDGET
                    push_analysis_incomplete!(
                        diags,
                        policy,
                        path,
                        source,
                        pos,
                        pos + syntax_span(node) - 1,
                        TEST_INTEGRITY_RULE,
                    )
                end
            end
        elseif mname == "test_throws"
            args, argpos = _macrocall_args(node, pos)
            if !isempty(args) && _exception_type_too_broad(args[1], source, argpos[1])
                _push_test_integrity!(
                    diags,
                    policy,
                    path,
                    source,
                    pos,
                    pos + syntax_span(node) - 1,
                    "@test_throws uses overly broad exception type ($(strip(_node_text(source, argpos[1], args[1]))))",
                )
            end
        end
    elseif track_exit && syntax_kind(node) == KCall && _is_exit_call(node, source, pos)
        _push_test_integrity!(
            diags,
            policy,
            path,
            source,
            pos,
            pos + syntax_span(node) - 1,
            "exit(...) must not run before the test suite finishes",
        )
    end
    child_track = track_exit && syntax_kind(node) != KFunction && syntax_kind(node) != KMacro
    for (c, cp) in _child_positions(node, pos)[1]
        syntax_is_trivia(c) || _walk_test_integrity_node!(diags, policy, path, source, consts, c, cp, child_track)
    end
    return nothing
end

function _walk_test_integrity_syntax!(
        diags::Vector{Violation},
        policy::PolicyBundle,
        path::String,
        source::AbstractString,
        tree::SyntaxTree,
        consts::Dict{String, TestFoldConst},
        exit_scope::Bool,
    )
    _walk_test_integrity_node!(diags, policy, path, source, consts, tree, 1, exit_scope)
    return nothing
end

function _parse_kw_tolerance(parameters_node::SyntaxTree, src::AbstractString, pos::Int)
    atol = nothing
    rtol = nothing
    for (c, cp) in _child_positions(parameters_node, pos)[1]
        syntax_kind(c) == KAssign || continue
        key = ""
        val_node = nothing
        val_pos = 0
        for (cc, cpp) in _child_positions(c, cp)[1]
            syntax_is_trivia(cc) && continue
            if syntax_kind(cc) == KIdentifier && isempty(key)
                key = _node_text_trim(cc, src, cpp)
            elseif syntax_kind(cc) in (KFloat, KInteger)
                val_node = cc
                val_pos = cpp
            end
        end
        key in ("atol", "rtol") || continue
        val_node === nothing && continue
        v = _parse_float_node(val_node, src, val_pos)
        if v === nothing && syntax_kind(val_node) == KInteger
            iv = _parse_int_node(val_node, src, val_pos)
            iv !== nothing && (v = Float64(iv))
        end
        v === nothing && continue
        key == "atol" && (atol = v)
        key == "rtol" && (rtol = v)
    end
    return atol, rtol
end

function _approx_arg_signature(node::SyntaxTree, src::AbstractString, pos::Int)
    syntax_kind(node) == KCall || return ""
    parts = String[]
    seen_callee = false
    for (c, cp) in _child_positions(node, pos)[1]
        syntax_is_trivia(c) && continue
        syntax_kind(c) == KParameters && break
        if !seen_callee
            seen_callee = true
            continue
        end
        k = syntax_kind(c)
        if k in (KFloat, KInteger, KIdentifier, KStringExpr, KBool)
            push!(parts, string(k) * ":" * _node_text_trim(c, src, cp))
        elseif k == KCall || k == KDot
            push!(parts, _node_text_trim(c, src, cp))
        else
            push!(parts, string(k))
        end
    end
    return join(parts, ",")
end

function _call_is_approx(node::SyntaxTree, src::AbstractString, pos::Int)
    syntax_kind(node) == KCall || return false
    callee = _call_callee_ident(node, src, pos)
    callee == "isapprox" && return true
    callee == "≈" && return true
    for (c, cp) in _child_positions(node, pos)[1]
        syntax_kind(c) == KIdentifier && _node_text_trim(c, src, cp) == "≈" && return true
    end
    return false
end

function _walk_approx_snaps!(
        out::Vector{ApproxTolSnapshot},
        node::SyntaxTree,
        pos::Int,
        src::AbstractString,
        testset::String,
        ordinals::Dict{Tuple{String, String}, Int},
    )
    if _call_is_approx(node, src, pos)
        arg_sig = _approx_arg_signature(node, src, pos)
        isempty(arg_sig) && return nothing
        bucket = (testset, arg_sig)
        ordinals[bucket] = get(ordinals, bucket, 0) + 1
        within = ordinals[bucket]
        pairing_key = "$(testset)\0$(within)\0$(arg_sig)"
        atol = nothing
        rtol = nothing
        for (c, cp) in _child_positions(node, pos)[1]
            syntax_kind(c) == KParameters || continue
            atol, rtol = _parse_kw_tolerance(c, src, cp)
        end
        sp = span_from_byte_range(src, pos, pos + syntax_span(node) - 1)
        push!(
            out,
            ApproxTolSnapshot(
                testset,
                arg_sig,
                within,
                pairing_key,
                sp.start_line,
                pos,
                pos + syntax_span(node) - 1,
                atol,
                rtol,
            ),
        )
    end
    if syntax_kind(node) == KMacrocall && _ti_macrocall_name(node, src, pos) == "testset"
        args, argpos = _macrocall_args(node, pos)
        child_ts = ""
        if !isempty(args)
            lit = _folded_string_arg(args[1], src, argpos[1])
            lit !== nothing && (child_ts = lit)
        end
        for (c, cp) in _child_positions(node, pos)[1]
            syntax_is_trivia(c) || _walk_approx_snaps!(out, c, cp, src, child_ts, ordinals)
        end
        return nothing
    end
    for (c, cp) in _child_positions(node, pos)[1]
        syntax_is_trivia(c) || _walk_approx_snaps!(out, c, cp, src, testset, ordinals)
    end
    return nothing
end

function _collect_approx_tolerances(tree::SyntaxTree, src::AbstractString)::Vector{ApproxTolSnapshot}
    out = ApproxTolSnapshot[]
    ordinals = Dict{Tuple{String, String}, Int}()
    _walk_approx_snaps!(out, tree, 1, src, "<toplevel>", ordinals)
    return out
end

function _tol_grew(base::Union{Nothing, Float64}, head::Union{Nothing, Float64})
    head === nothing && return false
    base === nothing && return true
    return head > base
end

function literal_include_graph(runtests_src::AbstractString; tree = nothing)
    paths = String[]
    src = normalize_source(runtests_src)
    greentree = tree === nothing ? parse_source(src; filename = RUNTESTS_REL) : tree
    push!(paths, RUNTESTS_REL)
    for inc in _top_level_include_paths(greentree, src)
        rel = normalize_path(inc)
        !startswith(rel, "test/") && (rel = "test/" * lstrip(rel, '/'))
        push!(paths, rel)
    end
    return unique(paths)
end

function _file_test_integrity_syntax(fc::FileContext, policy::PolicyBundle, exit_scope::Bool)
    path = fc.parsed.path
    !_under_test_tree(path) && return Violation[]
    !julia_source_path(path) && return Violation[]
    source = fc.parsed.normalized
    tree = fc.tree
    tree === nothing && return Violation[]
    consts = collect_toplevel_const_bindings(tree, source)
    diags = Violation[]
    _walk_test_integrity_syntax!(diags, policy, path, source, tree, consts, exit_scope)
    return diags
end

function _diff_test_skip_broken!(
        diags::Vector{Violation},
        policy::PolicyBundle,
        root::AbstractString,
        path::String,
        head_src::AbstractString,
        base_ref::AbstractString;
        head_tree = nothing,
    )
    sha = git_resolve_commit_sha(root, base_ref)
    ht = head_tree === nothing ? parse_source(head_src; filename = path) : head_tree
    counts = _count_macro_ops(ht, head_src, _SKIP_BROKEN_MACROS)
    base_counts = if git_tree_path_exists(root, sha, path)
        base_src = git_show_blob_at_commit(root, sha, path)
        base_tree = parse_source(base_src; filename = path)
        _count_macro_ops(base_tree, base_src, _SKIP_BROKEN_MACROS)
    else
        Dict(m => 0 for m in _SKIP_BROKEN_MACROS)
    end
    for m in _SKIP_BROKEN_MACROS
        get(counts, m, 0) <= get(base_counts, m, 0) && continue
        ln, b0, b1 = _first_macro_line(ht, head_src, m)
        ln == 0 && (b0 = 1; b1 = min(4, ncodeunits(head_src)))
        _push_test_integrity!(
            diags,
            policy,
            path,
            head_src,
            b0,
            b1,
            "@$m count increased ($(get(base_counts, m, 0)) -> $(get(counts, m, 0)))",
        )
    end
    return nothing
end

function _diff_runtests_removed!(
        diags::Vector{Violation},
        policy::PolicyBundle,
        root::AbstractString,
        head_src::AbstractString,
        base_ref::AbstractString;
        head_tree = nothing,
    )
    path = RUNTESTS_REL
    sha = git_resolve_commit_sha(root, base_ref)
    git_tree_path_exists(root, sha, path) || return
    base_src = git_show_blob_at_commit(root, sha, path)
    base_tree = parse_source(base_src; filename = path)
    ht = head_tree === nothing ? parse_source(head_src; filename = path) : head_tree
    base_entries = Set((e.kind, e.key) for e in _runtests_entries(base_tree, base_src))
    head_entries = Set((e.kind, e.key) for e in _runtests_entries(ht, head_src))
    for ek in base_entries
        ek in head_entries && continue
        kind, key = ek
        label = kind == :include ? "include($key)" : "@testset \"$key\""
        _push_test_integrity!(
            diags,
            policy,
            path,
            head_src,
            1,
            min(ncodeunits(head_src), 4),
            "removed from test/runtests.jl: $label",
        )
    end
    return nothing
end

function _diff_approx_tolerances!(
        diags::Vector{Violation},
        policy::PolicyBundle,
        path::String,
        head_src::AbstractString,
        base_src::AbstractString,
        changed::Set{Int};
        head_tree = nothing,
    )
    ht = head_tree === nothing ? parse_source(head_src; filename = path) : head_tree
    base_tree = parse_source(base_src; filename = path)
    head_snaps = _collect_approx_tolerances(ht, head_src)
    base_snaps = _collect_approx_tolerances(base_tree, base_src)
    base_by_key = Dict{String, ApproxTolSnapshot}()
    for s in base_snaps
        !haskey(base_by_key, s.pairing_key) && (base_by_key[s.pairing_key] = s)
    end
    for snap in head_snaps
        on_changed = snap.line in changed
        !on_changed && continue
        base = get(base_by_key, snap.pairing_key, nothing)
        base === nothing && continue
        loosen = _tol_grew(base.atol, snap.atol) || _tol_grew(base.rtol, snap.rtol)
        loosen || continue
        _push_test_integrity!(
            diags,
            policy,
            path,
            head_src,
            snap.byte_start,
            snap.byte_end,
            "isapprox/≈ tolerance loosened vs base (atol=$(base.atol) rtol=$(base.rtol) -> atol=$(snap.atol) rtol=$(snap.rtol))",
        )
    end
    return nothing
end

function _normalize_test_include_path(path::AbstractString)
    p = normalize_path(path)
    !startswith(p, "test/") && (p = "test/" * lstrip(p, '/'))
    return p
end

function _include_paths_match(a::AbstractString, b::AbstractString)
    return _normalize_test_include_path(a) == _normalize_test_include_path(b)
end

function _head_runtests_normalized(contexts::Vector{FileContext}, root::AbstractString)
    for fc in contexts
        fc.parsed.path == RUNTESTS_REL && return fc.parsed.normalized
    end
    ap = joinpath(abspath(root), RUNTESTS_REL)
    isfile(ap) || return ""
    return normalize_source(read(ap, String))
end

function _base_runtests_include_set(root::AbstractString, sha::AbstractString)
    git_tree_path_exists(root, sha, RUNTESTS_REL) || return Set{String}()
    base_src = git_show_blob_at_commit(root, sha, RUNTESTS_REL)
    return Set(_normalize_test_include_path(p) for p in literal_include_graph(base_src) if p != RUNTESTS_REL)
end

function _head_runtests_include_set(head_src::AbstractString; tree = nothing)
    isempty(head_src) && return Set{String}()
    return Set(
        _normalize_test_include_path(p) for p in literal_include_graph(head_src; tree = tree) if p != RUNTESTS_REL
    )
end

function _diff_anchor_for_deleted(diff_scope::DiffScope, contexts::Vector{FileContext}, root::AbstractString)
    for f in diff_scope.files
        f.status in ('A', 'M') || continue
        startswith(f.path, "test/") || continue
        for fc in contexts
            fc.parsed.path == f.path && return (f.path, fc.parsed.normalized)
        end
    end
    for fc in contexts
        fc.parsed.path == RUNTESTS_REL && return (RUNTESTS_REL, fc.parsed.normalized)
    end
    ap = joinpath(abspath(root), RUNTESTS_REL)
    isfile(ap) && return (RUNTESTS_REL, normalize_source(read(ap, String)))
    for f in diff_scope.files
        f.status in ('A', 'M') && return (f.path, "")
    end
    return (RUNTESTS_REL, "")
end

function _push_deleted_test_file!(
        diags::Vector{Violation},
        policy::PolicyBundle,
        anchor_path::String,
        anchor_src::AbstractString,
        diff_scope::DiffScope,
        deleted_rel::String,
        msg::String,
    )
    lvl = _test_integrity_level(policy)
    lvl == Level.ALLOW && return nothing
    intent, do_not = _test_integrity_spec(policy)
    report_path = _normalize_test_include_path(deleted_rel)
    if report_path != _normalize_test_include_path(RUNTESTS_REL) && !isempty(anchor_src)
        changed = diff_changed_lines(diff_scope, anchor_path)
        line = isempty(changed) ? 1 : minimum(changed)
        if anchor_path == RUNTESTS_REL
            key = replace(basename(deleted_rel), "\\" => "/")
            keyq = "\"$key\""
            for (i, ln) in enumerate(split(anchor_src, '\n'; keepempty = true))
                occursin("include", ln) && occursin(keyq, ln) && (line = i; break)
            end
        end
        b0, _, stop = line_byte_span(anchor_src, line)
        le = stop > b0 ? stop - 1 : b0
        b1 = min(le, ncodeunits(anchor_src))
        b1 < b0 && (b1 = min(4, ncodeunits(anchor_src)); b0 = 1)
        sp = span_from_byte_range(anchor_src, b0, b1)
        push!(
            diags,
            Violation(
                TEST_INTEGRITY_RULE,
                Origin.AGENTRULELINT,
                lvl,
                report_path,
                sp,
                sp.start_line,
                "",
                ExpectStatus.DELETED_TEST,
                false,
                msg,
                intent,
                do_not,
            ),
        )
        return nothing
    end
    push!(
        diags,
        Violation(
            TEST_INTEGRITY_RULE,
            Origin.AGENTRULELINT,
            lvl,
            report_path,
            Span(),
            0,
            "",
            ExpectStatus.DELETED_TEST,
            false,
            msg,
            intent,
            do_not,
        ),
    )
    return nothing
end

function _rename_covers_include(old_rel::String, head_includes::Set{String}, events::Vector{DiffPathEvent})
    for ev in events
        ev.status != 'R' && continue
        isempty(ev.old_path) && continue
        _include_paths_match(ev.old_path, old_rel) || continue
        new_rel = _normalize_test_include_path(ev.path)
        new_rel in head_includes && return true
        any(inc -> _include_paths_match(inc, new_rel), head_includes) && return true
    end
    return false
end

function _diff_deleted_test_files!(
        policy::PolicyBundle,
        root::AbstractString,
        diff_base::AbstractString,
        diff_scope::DiffScope,
        contexts::Vector{FileContext},
        path_events::Vector{DiffPathEvent},
    )
    diags = Violation[]
    sha = git_resolve_commit_sha(root, diff_base)
    anchor_path, anchor_src = _diff_anchor_for_deleted(diff_scope, contexts, root)
    head_rt = _head_runtests_normalized(contexts, root)
    runtests_tree = nothing
    for fc in contexts
        if fc.parsed.path == RUNTESTS_REL
            runtests_tree = fc.tree
            break
        end
    end
    head_includes = _head_runtests_include_set(head_rt; tree = runtests_tree)
    base_includes = _base_runtests_include_set(root, sha)

    for f in diff_scope.files
        if f.path == RUNTESTS_REL && f.status == 'D'
            _push_deleted_test_file!(
                diags,
                policy,
                anchor_path,
                anchor_src,
                diff_scope,
                RUNTESTS_REL,
                "deleted test/runtests.jl in diff",
            )
        end
    end
    for ev in path_events
        ev.status == 'R' || continue
        normalize_path(ev.old_path) != RUNTESTS_REL && continue
        _push_deleted_test_file!(
            diags,
            policy,
            anchor_path,
            anchor_src,
            diff_scope,
            RUNTESTS_REL,
            "deleted test/runtests.jl in diff",
        )
    end

    deleted_paths = Set{String}()
    for ev in path_events
        if ev.status == 'D'
            startswith(ev.path, "test/") &&
                push!(deleted_paths, _normalize_test_include_path(ev.path))
        elseif ev.status == 'R' && !isempty(ev.old_path)
            startswith(ev.old_path, "test/") &&
                push!(deleted_paths, _normalize_test_include_path(ev.old_path))
        end
    end

    for rel in deleted_paths
        rel == _normalize_test_include_path(RUNTESTS_REL) && continue
        _rename_covers_include(rel, head_includes, path_events) && continue
        covered = false
        for base_inc in base_includes
            _include_paths_match(base_inc, rel) || continue
            covered = true
            break
        end
        covered || continue
        _push_deleted_test_file!(
            diags,
            policy,
            anchor_path,
            anchor_src,
            diff_scope,
            rel,
            "deleted test file still referenced from base test/runtests.jl: $rel",
        )
    end
    return diags
end

function run_test_integrity(
        root::AbstractString,
        contexts::Vector{FileContext},
        policy::PolicyBundle;
        diff_base = nothing,
        diff_scope = nothing,
    )
    lvl = _test_integrity_level(policy)
    lvl == Level.ALLOW && return Violation[]
    root = abspath(String(root))
    exit_paths = Set{String}()
    runtests_fc = nothing
    for fc in contexts
        fc.parsed.path == RUNTESTS_REL && (runtests_fc = fc)
    end
    if runtests_fc !== nothing
        for p in literal_include_graph(runtests_fc.parsed.normalized; tree = runtests_fc.tree)
            push!(exit_paths, normalize_path(p))
        end
    else
        push!(exit_paths, RUNTESTS_REL)
    end

    diags = Violation[]
    for fc in contexts
        exit_scope = normalize_path(fc.parsed.path) in exit_paths
        append!(diags, _file_test_integrity_syntax(fc, policy, exit_scope))
    end

    diff_base === nothing && return diags

    sha = git_resolve_commit_sha(root, diff_base)
    if diff_scope !== nothing
        path_events = git_diff_path_events(root, diff_base)
        append!(diags, _diff_deleted_test_files!(policy, root, diff_base, diff_scope, contexts, path_events))
    end
    for fc in contexts
        path = fc.parsed.path
        !_under_test_tree(path) && continue
        !julia_source_path(path) && continue
        if diff_scope !== nothing
            st = diff_path_status(diff_scope, path)
            st == 'D' && continue
            changed = diff_changed_lines(diff_scope, path)
            isempty(changed) && continue
        else
            changed = Set{Int}()
        end
        head_src = fc.parsed.normalized
        _diff_test_skip_broken!(
            diags,
            policy,
            root,
            path,
            head_src,
            diff_base;
            head_tree = fc.tree,
        )
        if path == RUNTESTS_REL
            _diff_runtests_removed!(
                diags,
                policy,
                root,
                head_src,
                diff_base;
                head_tree = fc.tree,
            )
        end
        git_tree_path_exists(root, sha, path) || continue
        base_src = git_show_blob_at_commit(root, sha, path)
        _diff_approx_tolerances!(
            diags,
            policy,
            path,
            head_src,
            base_src,
            changed;
            head_tree = fc.tree,
        )
    end
    return diags
end

const TEST_INTEGRITY_RULE_DEF = RuleDef(
    TEST_INTEGRITY_RULE,
    Origin.AGENTRULELINT,
    Level.DENY,
    "Keep tests from being hollowed out or silently disabled.",
    "Replace assertions with trivially true forms, broaden throws, skip without reason, or drop covered tests.",
    Dict{Symbol, String}(),
    "test_integrity.jl",
    "test_test_integrity.jl",
    ("test/corpus/test_integrity_trivial_true.jl",),
)
