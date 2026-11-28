function format_agent(
        result::CheckResult;
        root::AbstractString = pwd(),
        max_hits::Union{Nothing, Int} = nothing,
        io::IO = stdout,
        output_width::Union{Nothing, Int} = nothing,
        _agentrulelint_version::Union{Nothing, AbstractString} = nothing, # test-only: override the displayed version (see test_output_goldens.jl)
    )
    io isa IO || throw(ArgumentError("io must be an IO"))
    excerpt_cap = resolve_agent_excerpt_cap(; output_width = output_width)
    hit_cap = something(max_hits, result.max_hits_per_rule)
    buf = IOBuffer()
    ceilings = result.ceilings
    base = config_source_base_label(result.config_source)
    groups = violations_by_rule(active_violations(result.violations))
    rule_hits = length(groups)
    status = result.exit_code == 0 ? "OK" : "FAIL"
    ver = something(_agentrulelint_version, string(AGENTRULELINT_VERSION))
    git_part = isempty(result.git_executable) ? "" : " git=$(result.git_executable)@$(result.git_version)"
    headline =
        "AGENTRULELINT $status v$ver base=$base pos=utf8-codepoint-1based$git_part violations=$(result.violation_count) rules=$rule_hits"
    extras = verdict_exit_paren(result)
    extras != "(exit $(result.exit_code))" && (headline *= " $extras")
    println(buf, headline)
    notice = format_config_notice_line(result.config_notice)
    !isempty(notice) && println(buf, notice)
    println(buf)
    for (rid, all_ds) in groups
        lvl = all_ds[1].level
        orig = origin_label(all_ds[1].origin)
        total = length(all_ds)
        ceiling = rule_violation_total(ceilings, rid)
        ceiling_s = ceiling > 0 ? string(ceiling) : "-"
        rule_line = "RULE $orig $rid level=$(wire_name(lvl)) count=$total ceiling=$ceiling_s"
        println(buf, rule_line)
        !isempty(all_ds[1].intent) && println(buf, "intent: ", all_ds[1].intent)
        !isempty(all_ds[1].do_not) && println(buf, "do_not: ", all_ds[1].do_not)
        limit = min(total, hit_cap)
        for i in 1:limit
            d = all_ds[i]
            snip = snippet_for_violation(root, d)
            loc = format_span_loc(d)
            if isempty(snip)
                println(buf, "HIT $loc | ", d.message)
            else
                excerpt = _agent_hit_excerpt(snip, excerpt_cap)
                println(buf, "HIT $loc | ", excerpt)
            end
        end
        total > limit && println(buf, "... (+$(total - limit) omitted)")
        println(buf)
    end
    return String(take!(buf))
end
