# uses normalize_source, standalone_comment_lines, span_for_line from SyntaxAdapter scope

const EXPECT_PREFIX = "agentrulelint-expect:"
const AGENTRULELINT_PREFIX = "agentrulelint"

const _MALFORMED_EXPECT = (
    status = :malformed,
    rule_ref = "",
    reason = "",
    message = "",
)

function parse_expect_body(body::AbstractString)
    body = strip(body)
    startswith(body, EXPECT_PREFIX) || return nothing
    rest = strip(body[(length(EXPECT_PREFIX) + 1):end])
    isempty(rest) &&
        return (; _MALFORMED_EXPECT..., message = "empty expect")
    if match(r"^\S+\s+reason=\"\"\s*$", rest) !== nothing
        return (; _MALFORMED_EXPECT..., message = "empty reason")
    end
    m = match(r"^(\S+)\s+reason=\"([^\"]+)\"$", rest)
    m === nothing && return (; _MALFORMED_EXPECT..., message = "missing reason=\"...\"")
    rule_ref = m.captures[1]
    reason = m.captures[2]
    rule_ref === nothing && return (; _MALFORMED_EXPECT..., message = "missing rule id")
    reason === nothing && return (; _MALFORMED_EXPECT..., message = "missing reason")
    isempty(strip(String(reason))) && return (; _MALFORMED_EXPECT..., message = "empty reason")
    return (
        status = :ok,
        rule_ref = String(rule_ref),
        reason = String(reason),
        message = "",
    )
end

function scan_block_comments(source::AbstractString)
    errs = Tuple{Int, String}[]
    pattern = r"#=([\s\S]*?)=#"
    for m in eachmatch(pattern, source)
        inner = m.captures[1]
        inner === nothing && continue
        occursin("agentrulelint-expect:", inner) || continue
        line = line_number_at_byte(source, m.offset)
        push!(errs, (line, "block comment expect forbidden"))
    end
    return errs
end

function detect_inline_expect_trailing(source::AbstractString)
    diags = Vector{Tuple{Int, String}}()
    for (i, line) in enumerate(split(normalize_source(source), '\n'))
        pos = findfirst("# agentrulelint-expect:", line)
        pos === nothing && continue
        cut = pos isa AbstractRange ? first(pos) : pos
        cut = cut isa Integer ? cut : first(cut)
        code = cut > 1 ? strip(line[1:prevind(line, cut)]) : ""
        !isempty(code) && push!(diags, (i, "trailing inline expect"))
    end
    return diags
end

function _push_malformed!(diags::Vector{Tuple{Int, String}}, seen::Set{Tuple{Int, String}}, line::Int, msg::String)
    key = (line, msg)
    key in seen && return
    push!(seen, key)
    push!(diags, key)
    return
end

function detect_malformed_agentrulelint(source::AbstractString)
    src = normalize_source(source)
    diags = Vector{Tuple{Int, String}}()
    seen = Set{Tuple{Int, String}}()
    for d in detect_inline_expect_trailing(src)
        d in seen && continue
        push!(seen, d)
        push!(diags, d)
    end
    standalone = standalone_comment_lines(src)
    for (i, line) in enumerate(split(src, '\n'))
        stripped = strip(line)
        startswith(stripped, "#") || continue
        body = strip(stripped[2:end])
        occursin(AGENTRULELINT_PREFIX, body) || continue
        if haskey(standalone, i)
            if startswith(body, "agentrulelint-expect:")
                parsed = parse_expect_body(body)
                if parsed === nothing
                    _push_malformed!(diags, seen, i, "malformed expect")
                elseif parsed.status == :malformed
                    _push_malformed!(diags, seen, i, String(parsed.message))
                end
            elseif startswith(body, "agentrulelint")
                _push_malformed!(diags, seen, i, "malformed # agentrulelint* directive")
            end
        end
    end
    return diags
end

function _line_is_standalone_hash_comment(line::AbstractString)
    pos = findfirst('#', line)
    pos === nothing && return false
    cut = pos isa AbstractRange ? first(pos) : pos
    cut = cut isa Integer ? cut : first(cut)
    code = cut > 1 ? strip(line[1:prevind(line, cut)]) : ""
    return isempty(code)
end

function extract_expect_lines_text(source::AbstractString)
    source = normalize_source(source)
    expects = ExpectLine[]
    for (line_no, line) in enumerate(split(source, '\n'))
        _line_is_standalone_hash_comment(line) || continue
        body = strip(strip(line)[2:end])
        startswith(body, EXPECT_PREFIX) || continue
        parsed = parse_expect_body(body)
        parsed === nothing && continue
        parsed.status == :malformed && continue
        parsed.status != :ok && continue
        push!(expects, ExpectLine(line_no, parsed.rule_ref, parsed.reason, body))
    end
    return expects
end

function extract_expect_lines(source::AbstractString)
    source = normalize_source(source)
    comments = standalone_comment_lines(source)
    expects = ExpectLine[]
    for (line_no, body) in comments
        startswith(body, EXPECT_PREFIX) || continue
        parsed = parse_expect_body(body)
        parsed === nothing && continue
        parsed.status == :malformed && continue
        parsed.status != :ok && continue
        push!(expects, ExpectLine(line_no, parsed.rule_ref, parsed.reason, body))
    end
    return expects
end

function detect_malformed_agentrulelint_text(source::AbstractString)
    src = normalize_source(source)
    diags = Vector{Tuple{Int, String}}()
    seen = Set{Tuple{Int, String}}()
    for d in detect_inline_expect_trailing(src)
        d in seen && continue
        push!(seen, d)
        push!(diags, d)
    end
    for (i, line) in enumerate(split(src, '\n'))
        _line_is_standalone_hash_comment(line) || continue
        body = strip(strip(line)[2:end])
        occursin(AGENTRULELINT_PREFIX, body) || continue
        if startswith(body, "agentrulelint-expect:")
            parsed = parse_expect_body(body)
            if parsed === nothing
                _push_malformed!(diags, seen, i, "malformed expect")
            elseif parsed.status == :malformed
                _push_malformed!(diags, seen, i, String(parsed.message))
            end
        elseif startswith(body, "agentrulelint")
            _push_malformed!(diags, seen, i, "malformed # agentrulelint* directive")
        end
    end
    return diags
end

function contiguous_expect_groups(expects::Vector{ExpectLine})
    isempty(expects) && return Vector{Vector{ExpectLine}}()
    sorted = sort(expects; by = e -> e.line)
    groups = Vector{ExpectLine}[]
    cur = ExpectLine[sorted[1]]
    for i in 2:length(sorted)
        if sorted[i].line == sorted[i - 1].line + 1
            push!(cur, sorted[i])
        else
            push!(groups, cur)
            cur = ExpectLine[sorted[i]]
        end
    end
    push!(groups, cur)
    return groups
end


function _push_expect_violation!(
        diags::Vector{Violation},
        msg::String,
        rule,
        path::String,
        source::AbstractString,
        line_no::Int,
        lvl::Level.T,
    )
    _, span = span_for_line(source, line_no)
    intent = rule === nothing ? "" : rule.intent
    do_not = rule === nothing ? "" : rule.do_not
    push!(
        diags,
        Violation(
            "expect-audit",
            Origin.AGENTRULELINT,
            lvl,
            path,
            span,
            line_no,
            "",
            ExpectStatus.UNFULFILLED,
            false,
            msg,
            intent,
            do_not,
        ),
    )
    return
end


function apply_expect_suppression!(diags::Vector{Violation}, expects::Vector{ExpectLine}, source::AbstractString)
    anchors = Dict{Int, Vector{ExpectLine}}()
    for g in contiguous_expect_groups(expects)
        anchor_li, _ = group_attachment_code_line(g, source)
        anchor_li == 0 && continue
        bucket = get!(anchors, anchor_li, ExpectLine[])
        for ex in g
            push!(bucket, ex)
        end
    end
    used_expect = Set{Int}()
    for (i, d) in enumerate(diags)
        d.suppressed && continue
        is_analysis_incomplete(d) && continue
        anchor = d.anchor_line
        group = get(anchors, anchor, nothing)
        group === nothing && continue
        for ex in group
            rule_ref_matches(ex.rule_ref, d.rule_id) || continue
            diags[i] = Violation(
                d.rule_id,
                d.origin,
                d.level,
                d.path,
                d.span,
                d.anchor_line,
                d.fingerprint,
                ExpectStatus.FULFILLED,
                true,
                d.message,
                d.intent,
                d.do_not,
            )
            push!(used_expect, ex.line)
            break
        end
    end
    return used_expect
end

"""
Non-Julia files: line-based expect-audit only (no `parse_source` / JuliaSyntax).
`# agentrulelint-expect:` on standalone `#` comment lines is parsed; placement uses the
next non-blank line as the attachment anchor (`rule_anchor_matches` for project rules).
Julia-only rules (catch, multiline-call interior, runic:off) are not applied.
"""
function expect_audit_text_diagnostics(fc::FileContext, policy::PolicyBundle)
    source = fc.parsed.normalized
    diags = Violation[]
    rule = get(policy.rules, "expect-audit", nothing)
    lvl = rule === nothing ? Level.FORBID : rule.level
    path = fc.parsed.path

    seen = Set{Tuple{Int, String}}()
    for (line_no, msg) in detect_malformed_agentrulelint_text(source)
        key = (line_no, msg)
        key in seen && continue
        push!(seen, key)
        _push_expect_violation!(diags, msg, rule, path, source, line_no, lvl)
    end

    for (line_no, msg) in scan_block_comments(source)
        key = (line_no, msg)
        key in seen && continue
        push!(seen, key)
        _push_expect_violation!(diags, msg, rule, path, source, line_no, lvl)
    end

    groups = contiguous_expect_groups(fc.expects)
    for g in groups
        last_e = maximum(e.line for e in g)
        code_li, code = group_attachment_code_line(g, source)
        if code_li > 0
            for ex in g
                rule_anchor_matches(ex.rule_ref, code) || _push_expect_violation!(
                    diags,
                    "expect not anchored to rule target syntax",
                    rule,
                    path,
                    source,
                    ex.line,
                    lvl,
                )
            end
        end
        code_li == 0 && continue
        if code_li > last_e + 1
            for ex in g
                _push_expect_violation!(
                    diags,
                    "blank line breaking expect attachment (unused)",
                    rule,
                    path,
                    source,
                    ex.line,
                    lvl,
                )
            end
        end
    end

    return diags
end

function expects_eligible_for_suppression_text(expects::Vector{ExpectLine}, source::AbstractString)
    isempty(expects) && return ExpectLine[]
    src = normalize_source(source)
    eligible = ExpectLine[]
    for g in contiguous_expect_groups(expects)
        anchor_li, code = group_attachment_code_line(g, src)
        anchor_li == 0 && continue
        last_e = maximum(e.line for e in g)
        anchor_li > last_e + 1 && continue
        for ex in g
            rule_anchor_matches(ex.rule_ref, code) || continue
            push!(eligible, ex)
        end
    end
    return eligible
end

function expect_audit_diagnostics(fc::FileContext, policy::PolicyBundle)
    source = fc.parsed.normalized
    diags = Violation[]
    rule = get(policy.rules, "expect-audit", nothing)
    lvl = rule === nothing ? Level.FORBID : rule.level
    path = fc.parsed.path

    seen = Set{Tuple{Int, String}}()
    for (line_no, msg) in detect_malformed_agentrulelint(source)
        key = (line_no, msg)
        key in seen && continue
        push!(seen, key)
        _push_expect_violation!(diags, msg, rule, path, source, line_no, lvl)
    end

    for (line_no, msg) in scan_block_comments(source)
        key = (line_no, msg)
        key in seen && continue
        push!(seen, key)
        _push_expect_violation!(diags, msg, rule, path, source, line_no, lvl)
    end

    runic_regions = runic_off_regions(source)
    call_arg_lines = multiline_call_interior_lines(source; tree = fc.tree)

    for ex in fc.expects
        if line_in_runic_off_region(ex.line, runic_regions)
            msg = "expect inside runic:off region forbidden"
            _push_expect_violation!(diags, msg, rule, path, source, ex.line, lvl)
        end
        ex.line in call_arg_lines && _push_expect_violation!(
            diags,
            "expect inside multiline call arguments",
            rule,
            path,
            source,
            ex.line,
            lvl,
        )
    end

    groups = contiguous_expect_groups(fc.expects)
    for g in groups
        last_e = maximum(e.line for e in g)
        code_li, code = group_attachment_code_line(g, source)
        if code_li > 0
            if line_is_catch_header(code)
                for ex in g
                    _push_expect_violation!(diags, "expect forbidden above catch", rule, path, source, ex.line, lvl)
                end
            else
                for ex in g
                    rule_anchor_matches(ex.rule_ref, code) || _push_expect_violation!(
                        diags,
                        "expect not anchored to rule target syntax",
                        rule,
                        path,
                        source,
                        ex.line,
                        lvl,
                    )
                end
            end
        end
        code_li == 0 && continue
        if code_li > last_e + 1
            for ex in g
                _push_expect_violation!(
                    diags,
                    "blank line breaking expect attachment (unused)",
                    rule,
                    path,
                    source,
                    ex.line,
                    lvl,
                )
            end
        end
    end

    return diags
end

const _PLACEMENT_SUBSUMES_UNUSED = (
    "blank line breaking expect attachment (unused)",
    "expect forbidden above catch",
    "expect inside multiline call arguments",
    "expect inside runic:off region forbidden",
)

function _placement_subsumes_unused(prior::Vector{Violation}, path::AbstractString, line::Int)
    for d in prior
        d.rule_id != "expect-audit" && continue
        d.path != path && continue
        d.anchor_line != line && continue
        for prefix in _PLACEMENT_SUBSUMES_UNUSED
            startswith(d.message, prefix) && return true
        end
    end
    return false
end

function unused_expect_diagnostics(
        expects::Vector{ExpectLine},
        used::Set{Int},
        fc::FileContext,
        policy::PolicyBundle,
        prior::Vector{Violation},
    )
    rule = get(policy.rules, "expect-audit", nothing)
    lvl = rule === nothing ? Level.FORBID : rule.level
    intent = rule === nothing ? "" : rule.intent
    do_not = rule === nothing ? "" : rule.do_not
    source = fc.parsed.normalized
    path = fc.parsed.path
    diags = Violation[]
    for ex in expects
        ex.line in used && continue
        _placement_subsumes_unused(prior, path, ex.line) && continue
        msg = "unused expect"
        _, span = span_for_line(source, ex.line)
        push!(
            diags,
            Violation(
                "expect-audit",
                Origin.AGENTRULELINT,
                lvl,
                path,
                span,
                ex.line,
                "",
                ExpectStatus.UNFULFILLED,
                false,
                msg,
                intent,
                do_not,
            ),
        )
    end
    return diags
end

function forbid_rule_suppression_attempt(expects::Vector{ExpectLine}, policy::PolicyBundle, fc::FileContext)
    diags = Violation[]
    rule = get(policy.rules, "expect-audit", nothing)
    lvl = rule === nothing ? Level.FORBID : rule.level
    source = fc.parsed.normalized
    path = fc.parsed.path
    for ex in expects
        is_forbid_rule(policy, ex.rule_ref) || continue
        _, span = span_for_line(source, ex.line)
        msg = "forbid rule suppression"
        push!(
            diags,
            Violation(
                "expect-audit",
                Origin.AGENTRULELINT,
                lvl,
                path,
                span,
                ex.line,
                "",
                ExpectStatus.UNFULFILLED,
                false,
                msg,
                rule === nothing ? "" : rule.intent,
                rule === nothing ? "" : rule.do_not,
            ),
        )
    end
    return diags
end
