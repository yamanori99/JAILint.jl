const OUTPUT_WIDTH_CAP = 80

const ELLIPSIS_CHAR = "…"

const _ansi_pattern = r"\e\[[0-9;]*m"

function strip_ansi(s::AbstractString)
    return replace(s, _ansi_pattern => "")
end

function visible_textwidth(s::AbstractString)
    return Base.Unicode.textwidth(strip_ansi(s))
end

function _unwrap_io(io::IO)
    while io isa IOContext
        io = io.io
    end
    return io
end

function output_stream_is_tty(io::IO)
    return _unwrap_io(io) isa Base.TTY
end

"""
    tty_column_width(io::IO=stdout) -> Int

Return `min(cols, OUTPUT_WIDTH_CAP)` where `cols` is the column count from
`displaysize(io)` on a TTY (undefined on non-TTY streams).
"""
function tty_column_width(io::IO = stdout)
    _, cols = displaysize(io)
    return min(cols, OUTPUT_WIDTH_CAP)
end

"""
    resolve_human_output_width(io; output_width=nothing) -> Int

When `output_width` is set, use it (tests and explicit pin). Otherwise wrap only
on a TTY at `tty_column_width`; piped/file/agent-tool streams do not wrap and
`ENV["COLUMNS"]` is ignored (returns `typemax(Int)`).
"""
function resolve_human_output_width(io::IO = stdout; output_width::Union{Nothing, Int} = nothing)
    output_width !== nothing && return output_width
    output_stream_is_tty(io) || return typemax(Int)
    return tty_column_width(io)
end

const AGENT_EXCERPT_CAP = OUTPUT_WIDTH_CAP

"""
    resolve_agent_excerpt_cap(; output_width=nothing) -> Int

Cap for the source excerpt on agent `HIT` lines only (#80). Default
`AGENT_EXCERPT_CAP`. Pass `output_width` only in tests.
"""
function resolve_agent_excerpt_cap(; output_width::Union{Nothing, Int} = nothing)
    return something(output_width, AGENT_EXCERPT_CAP)
end

function _agent_hit_excerpt(body::AbstractString, cap::Int)
    visible_textwidth(body) <= cap && return body
    return _truncate_chars(body, cap, with_ellipsis = true)
end

function _prose_budget(prefix::AbstractString, width::Int)
    w = width - visible_textwidth(prefix)
    return max(w, 1)
end

function _truncate_chars_with_omitted(text::AbstractString, maxw::Int; with_ellipsis::Bool = true)
    isempty(text) && return ("", 0)
    if visible_textwidth(text) <= maxw
        return (text, 0)
    end
    maxw <= 0 && return (with_ellipsis ? ELLIPSIS_CHAR : "", length(text))
    reserve = with_ellipsis ? visible_textwidth(ELLIPSIS_CHAR) : 0
    limit = maxw - reserve
    limit <= 0 && return (with_ellipsis ? ELLIPSIS_CHAR : "", length(text))
    w = 0
    last_i = nothing
    stopped_early = false
    for i in eachindex(text)
        cw = Base.Unicode.textwidth(text[i])
        if w + cw > limit
            stopped_early = true
            break
        end
        w += cw
        last_i = i
    end
    last_i === nothing && return (with_ellipsis ? ELLIPSIS_CHAR : "", length(text))
    fi = firstindex(text)
    body = fi <= last_i ? text[fi:last_i] : ""
    omitted = stopped_early ? length(text) - length(body) : 0
    needs_ellipsis = with_ellipsis && stopped_early
    display = needs_ellipsis ? body * ELLIPSIS_CHAR : body
    return (display, omitted)
end

function _truncate_chars(text::AbstractString, maxw::Int; with_ellipsis::Bool = true)
    display, _ = _truncate_chars_with_omitted(text, maxw; with_ellipsis = with_ellipsis)
    return display
end

"""
    _human_gutter_excerpt(body, cap=AGENT_EXCERPT_CAP) -> (excerpt, line_suffix, omitted_chars)

Truncate a source line for human `> ` gutter at `cap` visible width (fixed cap, not TTY
width). When truncated, `line_suffix` is `" (+N chars omitted)"` for the same line;
otherwise empty. `excerpt` is the truncated body (with ellipsis when cut) for spans.
"""
function _human_gutter_excerpt(body::AbstractString, cap::Int = AGENT_EXCERPT_CAP)
    excerpt, omitted = _truncate_chars_with_omitted(body, cap)
    suffix = omitted > 0 ? " (+$omitted chars omitted)" : ""
    return (excerpt, suffix, omitted)
end

function _wrap_char_chunks(text::AbstractString, budget::Int)
    isempty(text) && return [""]
    lines = String[]
    line_start = firstindex(text)
    last_i = lastindex(text)
    while line_start <= last_i
        w = 0
        chunk_end = nothing
        i = line_start
        while i <= last_i
            cw = Base.Unicode.textwidth(text[i])
            if w + cw > budget
                break
            end
            w += cw
            chunk_end = i
            i === last_i && break
            i = nextind(text, i)
        end
        chunk_end === nothing && (chunk_end = line_start)
        push!(lines, text[line_start:chunk_end])
        chunk_end >= last_i && break
        line_start = nextind(text, chunk_end)
    end
    isempty(lines) && push!(lines, "")
    return lines
end

function _wrap_words(text::AbstractString, budget::Int)
    isempty(text) && return [""]
    words = String[]
    for m in eachmatch(r"\S+", String(text))
        push!(words, m.match)
    end
    isempty(words) && return [""]
    lines = String[]
    cur = ""
    for word in words
        candidate = isempty(cur) ? word : cur * " " * word
        if visible_textwidth(candidate) <= budget
            cur = candidate
        elseif isempty(cur)
            if visible_textwidth(word) <= budget
                cur = word
            else
                append!(lines, _wrap_char_chunks(word, budget))
            end
        else
            push!(lines, cur)
            if visible_textwidth(word) <= budget
                cur = word
            else
                append!(lines, _wrap_char_chunks(word, budget))
                cur = ""
            end
        end
    end
    !isempty(cur) && push!(lines, cur)
    return lines
end

function wrap_prose_lines(
        first_prefix::AbstractString,
        cont_prefix::AbstractString,
        text::AbstractString,
        width::Int,
    )
    budget = _prose_budget(first_prefix, width)
    chunks = _wrap_words(text, budget)
    lines = String[]
    for (i, chunk) in enumerate(chunks)
        prefix = i == 1 ? first_prefix : cont_prefix
        push!(lines, prefix * chunk)
    end
    return lines
end

function wrap_labeled_prose(margin::AbstractString, label::AbstractString, text::AbstractString, width::Int)
    first_prefix = string(margin, label)
    cont_prefix = string(margin, repeat(' ', Base.Unicode.textwidth(label)))
    return wrap_prose_lines(first_prefix, cont_prefix, text, width)
end

function truncate_quoted_line(prefix::AbstractString, body::AbstractString, width::Int)
    line = string(prefix, body)
    visible_textwidth(line) <= width && return line
    budget = width - visible_textwidth(prefix) - visible_textwidth(ELLIPSIS_CHAR)
    budget < 1 && return string(prefix, ELLIPSIS_CHAR)
    return string(prefix, _truncate_chars(body, budget, with_ellipsis = true))
end

function println_wrapped_labeled(buf::IO, margin::AbstractString, label::AbstractString, text::AbstractString, width::Int)
    for ln in wrap_labeled_prose(margin, label, text, width)
        println(buf, ln)
    end
    return nothing
end
