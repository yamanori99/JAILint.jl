function _human_console_head_styled(io::IO, level::Level.T)
    plain = human_console_level(level)
    color_enabled(io) || return plain
    if level in HUMAN_LEVEL_RED
        return emit_plain_or_styled(io, plain; color = :red)
    elseif level in HUMAN_LEVEL_YELLOW
        return emit_plain_or_styled(io, plain; color = :yellow)
    end
    return plain
end

function _human_group_header(
        io::IO,
        label::AbstractString,
        rule_id::AbstractString,
        level::Level.T,
        total::Int,
        ceiling_s::AbstractString,
    )
    head = _human_console_head_styled(io, level)
    counts = human_violation_phrase(total)
    return "┌ $head: $label $rule_id [$(wire_name(level))] ($counts, ceiling $ceiling_s)"
end

function format_human(
        result::CheckResult;
        root::AbstractString = pwd(),
        io::IO = stdout,
        output_width::Union{Nothing, Int} = nothing,
        _agentrulelint_version::Union{Nothing, AbstractString} = nothing, # test-only: override the displayed version (see test_output_goldens.jl)
    )
    width = resolve_human_output_width(io; output_width = output_width)
    buf = IOBuffer()
    ceilings = result.ceilings
    groups = violations_by_rule(active_violations(result.violations))
    max_hits = result.max_hits_per_rule
    cfg_label = result.config_source.path

    ver = something(_agentrulelint_version, string(AGENTRULELINT_VERSION))
    banner = human_policy_banner(result, ver)
    println(buf, banner)
    notice = format_config_notice_line(result.config_notice)
    !isempty(notice) && println(buf, notice)
    println(buf)

    for (rule_id, ds) in groups
        d0 = ds[1]
        label = origin_label(d0.origin)
        total = length(ds)
        ceiling_s = human_ceiling_display(ceilings, rule_id)
        header = _human_group_header(io, label, rule_id, d0.level, total, ceiling_s)
        if visible_textwidth(header) <= width
            println(buf, header)
        else
            println(buf, _truncate_chars(header, width, with_ellipsis = true))
        end
        println_wrapped_labeled(buf, "│   ", "intent: ", d0.intent, width)
        println_wrapped_labeled(buf, "│   ", "do_not: ", d0.do_not, width)
        println(buf, "│")

        limit = min(total, max_hits)
        for i in 1:limit
            d = ds[i]
            loc_body = format_span_loc(d)
            (d.span == Span(1, 1, 1, 1) && d.anchor_line == 1) && (loc_body = d.path)
            loc_line = "│   $loc_body"
            if visible_textwidth(loc_line) <= width
                println(buf, loc_line)
            else
                println(buf, _truncate_chars(loc_line, width, with_ellipsis = true))
            end
            !isempty(d.message) &&
                println_wrapped_labeled(buf, "│     ", "", d.message, width)
            line = source_line_at(root, d)
            !isempty(line) && println_human_code_gutter(buf, width, line, d.span)
        end

        if total > limit
            omit = "│     ... (+$(total - limit) omitted)"
            for ln in wrap_prose_lines("", "", omit, width)
                println(buf, ln)
            end
        end

        footer = human_rule_footer(rule_id, d0.origin, cfg_label)
        for ln in wrap_prose_lines("", "", footer, width)
            println(buf, ln)
        end
        println(buf)
    end

    rule_hits = length(groups)
    status = result.exit_code == 0 ? "PASSED" : "FAILED"
    by_origin = human_summary_by_origin(groups)
    summary =
        "Summary: $(result.violation_count) violations across $rule_hits rules ($by_origin) — $status $(verdict_exit_paren(result))"
    println(buf, summary)
    return String(take!(buf))
end
