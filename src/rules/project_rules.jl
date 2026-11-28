function _effective_project_level(policy::PolicyBundle, pr::ProjectRule)
    pr.level == Level.ALLOW && return policy.on_allow_rule
    return pr.level
end

function _text_literal_spans(source::AbstractString, lit::AbstractString)
    out = Tuple{Int, Int}[]
    start = firstindex(source)
    while true
        r = findnext(lit, source, start)
        r === nothing && break
        push!(out, (first(r), last(r)))
        start = last(r) < lastindex(source) ? nextind(source, last(r)) : lastindex(source) + 1
        start > lastindex(source) && break
    end
    return out
end

function _push_project_violation!(
        diags::Vector{Violation},
        rule_id::String,
        eff_level::Level.T,
        path::String,
        source::AbstractString,
        byte_start::Int,
        byte_end::Int,
        msg::String,
        intent::String,
        do_not::String,
    )
    sp = span_from_byte_range(source, byte_start, byte_end)
    push!(
        diags,
        Violation(
            rule_id,
            Origin.PROJECT,
            eff_level,
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

function _run_project_rules_julia!(
        diags::Vector{Violation},
        fc::FileContext,
        policy::PolicyBundle,
        pr::ProjectRule,
        rule_id::String,
        eff_level::Level.T,
    )
    path = fc.parsed.path
    source = fc.parsed.normalized
    tree = fc.tree
    tree === nothing && return nothing
    collected = collect_folded_string_exprs(tree, source)
    for lit in pr.forbid_literals
        seen_spans = Set{Tuple{Int, Int}}()
        for fold in collected.folds
            occursin(lit, fold.value) || continue
            keyspan = (fold.byte_start, fold.byte_end)
            keyspan in seen_spans && continue
            push!(seen_spans, keyspan)
            msg = "forbidden literal matched (folded)"
            _push_project_violation!(
                diags,
                rule_id,
                eff_level,
                path,
                source,
                fold.byte_start,
                fold.byte_end,
                msg,
                pr.intent,
                pr.do_not,
            )
        end
        for (c, p) in _child_positions(tree, 1)[1]
            syntax_kind(c) == KStringExpr || continue
            raw = _collect_string_chars(c, source, p)
            raw === nothing && continue
            occursin(lit, raw) || continue
            msg = "forbidden literal matched"
            _push_project_violation!(
                diags,
                rule_id,
                eff_level,
                path,
                source,
                p,
                p + syntax_span(c) - 1,
                msg,
                pr.intent,
                pr.do_not,
            )
        end
    end
    if collected.budget_exceeded
        at = max(1, collected.at_byte)
        push_analysis_incomplete!(diags, policy, path, source, at, at, rule_id)
    end
    return nothing
end

function _run_project_rules_text!(
        diags::Vector{Violation},
        fc::FileContext,
        pr::ProjectRule,
        rule_id::String,
        eff_level::Level.T,
    )
    path = fc.parsed.path
    source = fc.parsed.normalized
    for lit in pr.forbid_literals
        for (bs, be) in _text_literal_spans(source, lit)
            msg = "forbidden literal matched"
            _push_project_violation!(
                diags,
                rule_id,
                eff_level,
                path,
                source,
                bs,
                be,
                msg,
                pr.intent,
                pr.do_not,
            )
        end
    end
    return nothing
end

function run_project_rules(fc::FileContext, policy::PolicyBundle)
    path = fc.parsed.path
    diags = Violation[]
    for pr in policy.project_rules
        path_matches_glob(path, pr.path_regexes) || continue
        rule_id = project_rule_id(pr)
        eff_level = _effective_project_level(policy, pr)
        eff_level == Level.ALLOW && continue
        if julia_source_path(path)
            _run_project_rules_julia!(diags, fc, policy, pr, rule_id, eff_level)
        else
            _run_project_rules_text!(diags, fc, pr, rule_id, eff_level)
        end
    end
    return diags
end
