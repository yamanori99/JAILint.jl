const HUMAN_LEVEL_RED = (Level.FORBID, Level.DENY)
const HUMAN_LEVEL_YELLOW = (Level.WARN,)

function active_violations(vs::Vector{Violation})
    out = Violation[]
    for d in vs
        is_violation_hit(d) || continue
        push!(out, d)
    end
    return out
end

function diag_sort_key(d::Violation)
    return (d.path, d.span, d.rule_id, d.message, d.fingerprint)
end

function violations_by_rule(vs::Vector{Violation})
    by = Dict{String, Vector{Violation}}()
    for d in vs
        push!(get!(by, d.rule_id, Violation[]), d)
    end
    for ds in values(by)
        sort!(ds; by = diag_sort_key)
    end
    return sort(collect(by); by = first)
end

function rule_violation_total(ceilings::CeilingEntry, rule_id::String)
    bucket = get(ceilings.violations, rule_id, nothing)
    bucket === nothing && return 0
    return sum(values(bucket))
end

function format_span_loc(d::Violation)
    sl = d.span
    return "$(d.path):$(sl.start_line):$(sl.start_col)-$(sl.end_line):$(sl.end_col)"
end

function source_line_at(root::AbstractString, d::Violation)
    path = joinpath(root, d.path)
    !isfile(path) && return ""
    source = normalize_source(read(path, String))
    lines = split(source, '\n')
    d.anchor_line > length(lines) && return ""
    return String(lines[d.anchor_line])
end

function underline_for_span(line::AbstractString, span::Span; marker::Char = '^')
    isempty(line) && return ""
    n = length(line)
    sc = clamp(span.start_col, 1, max(n, 1))
    ec = clamp(span.end_col, sc, max(n, 1))
    buf = IOBuffer()
    for col in 1:n
        if col < sc
            write(buf, ' ')
        elseif col <= ec
            write(buf, marker)
        end
    end
    return String(take!(buf))
end

function human_console_level(level::Level.T)
    return level in HUMAN_LEVEL_YELLOW ? "Warning" : "Error"
end

function human_violation_phrase(n::Int)
    return n == 1 ? "1 violation" : "$n violations"
end

function human_ceiling_display(ceilings::CeilingEntry, rule_id::String)
    total = rule_violation_total(ceilings, rule_id)
    return string(total)
end

function human_policy_banner(result::CheckResult, version::AbstractString)
    cs = result.config_source
    base = if cs.kind == ConfigSourceKind.GIT_REF && !isempty(cs.ref)
        sha = isempty(cs.sha) ? "?" : cs.sha
        "policy bundle base: $(cs.ref) @ $sha"
    elseif cs.kind == ConfigSourceKind.PATH && !isempty(cs.path)
        "policy bundle base: $(cs.path)"
    elseif cs.kind == ConfigSourceKind.BUILTIN
        "policy bundle base: builtin"
    else
        "policy bundle base: $(wire_name(cs.kind))"
    end
    git_s = if isempty(result.git_executable)
        ""
    else
        ", git: $(result.git_executable) @ $(result.git_version)"
    end
    return "AgentRuleLint v$version ($base, pos: utf8-line-col$git_s)"
end

function _below_threshold_phrase(result::CheckResult)
    n = result.below_threshold_count
    n <= 0 && return ""
    word = n == 1 ? "finding" : "findings"
    result.below_threshold_mixed && return "$n $word below threshold"
    lvl = result.below_threshold_level
    lvl === nothing && return ""
    return "$n $(wire_name(lvl)) $word below threshold"
end

"""Parenthetical verdict clause from `CheckResult` fields only (never policy)."""
function verdict_exit_paren(result::CheckResult)
    parts = String["exit $(result.exit_code)"]
    if result.exit_severity_source == SeveritySource.CLI && result.exit_severity != result.baseline_exit_severity
        baseline_word = result.baseline_exit_severity_source == SeveritySource.DEFAULT ? "default" : "config"
        push!(
            parts,
            "threshold $(wire_name(result.exit_severity)) from --exit-severity, $(baseline_word) $(wire_name(result.baseline_exit_severity))",
        )
    end
    below = _below_threshold_phrase(result)
    !isempty(below) && push!(parts, below)
    return "(" * join(parts, "; ") * ")"
end


function _src_visible_body(src::AbstractString)
    endswith(src, ELLIPSIS_CHAR) || return src
    last = prevind(src, lastindex(src))
    return last < firstindex(src) ? "" : src[firstindex(src):last]
end

function human_underline_for_display(
        visible_line::AbstractString,
        span::Span;
        marker::Char = '~',
    )
    n = length(visible_line)
    n == 0 && return ""
    sc = clamp(span.start_col, 1, n)
    ec = clamp(span.end_col, sc, n)
    return underline_for_span(visible_line, Span(sc, sc, ec, ec); marker = marker)
end

function _human_gutter_underline_body(excerpt::AbstractString, span::Span; marker::Char = '~')
    visible = _src_visible_body(excerpt)
    ul_body = human_underline_for_display(visible, span; marker = marker)
    isempty(ul_body) && return ""
    ul = rstrip(ul_body, ' ')
    isempty(ul) && return ""
    if endswith(excerpt, ELLIPSIS_CHAR)
        n = length(visible)
        sc = clamp(span.start_col, 1, n)
        ec = clamp(span.end_col, sc, n)
        ec >= n && sc <= n && (ul = ul * ELLIPSIS_CHAR)
    end
    return ul
end

function human_rule_footer(rule_id::String, origin::Origin.T, config_path::AbstractString)
    if origin == Origin.AGENTRULELINT
        return "└ @ AgentRuleLint (run `agentrulelint explain $rule_id` for details)"
    elseif origin == Origin.PROJECT
        cfg = isempty(config_path) ? CONFIG_FILENAME : config_path
        return "└ @ Project $cfg ([[project_rules]])"
    elseif origin == Origin.PRESET
        return "└ @ $(origin_label(origin)) (run `agentrulelint explain $rule_id` for details)"
    else
        throw(InternalError("internal: unknown origin $origin"))
    end
end

const HUMAN_CODE_PREFIX = "│     > "
const HUMAN_UNDERLINE_PREFIX = "│       "

function _human_truncate_code(body::AbstractString, prefix::AbstractString, width::Int)
    budget = width - visible_textwidth(prefix)
    budget < 1 && return string(prefix, ELLIPSIS_CHAR)
    return string(prefix, _truncate_chars(body, budget, with_ellipsis = true))
end

function println_human_code_gutter(
        buf::IO,
        width::Int,
        line::AbstractString,
        span::Span,
    )
    width < 1 && error("internal: invalid human output width")
    line_prefix = HUMAN_CODE_PREFIX
    ul_prefix = HUMAN_UNDERLINE_PREFIX
    excerpt, omit_suffix, _ = _human_gutter_excerpt(line)
    println(buf, string(line_prefix, excerpt, omit_suffix))
    ul_display = _human_gutter_underline_body(excerpt, span; marker = '~')
    isempty(ul_display) && return nothing
    println(buf, string(ul_prefix, ul_display))
    return nothing
end

function human_summary_by_origin(groups)
    counts = Dict{String, Int}()
    for (_, ds) in groups
        label = origin_label(ds[1].origin)
        counts[label] = get(counts, label, 0) + 1
    end
    parts = String[]
    for (label, n) in sort(collect(counts))
        push!(parts, "$n $label")
    end
    return join(parts, ", ")
end

function color_enabled(io::IO)
    return get(io, :color, false)
end

function emit_plain_or_styled(io::IO, plain::AbstractString; color = nothing, bold = false)
    color_enabled(io) || return plain
    color === nothing && !bold && return plain
    buf = IOBuffer()
    ioctx = IOContext(buf, :color => true)
    if color === nothing
        printstyled(ioctx, plain; bold = bold)
    else
        printstyled(ioctx, plain; color = color, bold = bold)
    end
    return String(take!(buf))
end

function config_source_base_label(cs::ConfigSource)
    cs.kind == ConfigSourceKind.GIT_REF && !isempty(cs.ref) && return cs.ref
    cs.kind == ConfigSourceKind.PATH && !isempty(cs.path) && return cs.path
    return wire_name(cs.kind)
end

function snippet_for_violation(root::AbstractString, d::Violation)
    path = joinpath(root, d.path)
    !isfile(path) && return ""
    source = normalize_source(read(path, String))
    lines = split(source, '\n')
    d.anchor_line > length(lines) && return ""
    line = String(lines[d.anchor_line])
    return strip(slice_line_codepoint_cols(line, d.span.start_col, d.span.end_col))
end
