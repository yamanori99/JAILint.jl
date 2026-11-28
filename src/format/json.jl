using JSON: JSON

function _json_str(s::AbstractString)
    esc = replace(s, "\\" => "\\\\", "\"" => "\\\"", "\n" => "\\n", "\r" => "\\r", "\t" => "\\t")
    return "\"" * esc * "\""
end

function _json_val(v)
    v isa Bool && return v ? "true" : "false"
    v isa Integer && return string(v)
    v isa AbstractFloat && return string(v)
    v isa AbstractString && return _json_str(v)
    v isa Symbol && return _json_str(String(v))
    v isa Dict && return "{" * join([_json_str(string(k)) * ":" * _json_val(val) for (k, val) in sort(collect(v); by = first)], ",") * "}"
    v isa AbstractVector && return "[" * join(_json_val.(v), ",") * "]"
    return _json_str(string(v))
end

function format_json(result::CheckResult)
    lines = String[]
    header = Dict{String, Any}(
        "type" => "header",
        "version" => string(AGENTRULELINT_VERSION),
        "julia_version" => string(VERSION),
        "git_executable" => result.git_executable,
        "git_version" => result.git_version,
        "parser" => parser_rev_string(),
        "config_source" => config_source_dict(result.config_source),
        "position_encoding" => "utf8-codepoint-1based",
    )
    push!(lines, _json_val(header))
    for d in sort(result.violations; by = diag_sort_key)
        push!(lines, JSON.json(DiagnosticRecord(d)))
    end
    summary = Dict{String, Any}(
        "type" => "summary",
        "complete" => result.complete,
        "violations" => result.violation_count,
        "suppressed" => result.suppressed_count,
        "rules" => length(unique(d.rule_id for d in active_violations(result.violations))),
        "exit_code" => result.exit_code,
        "threshold" => wire_name(result.exit_severity),
        "threshold_source" => wire_name(result.exit_severity_source),
    )
    push!(lines, _json_val(summary))
    return join(lines, '\n') * '\n'
end
