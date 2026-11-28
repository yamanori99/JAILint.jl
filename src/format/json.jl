using JSON: JSON

function format_json(result::CheckResult)
    lines = String[]
    push!(lines, JSON.json(HeaderRecord(result)))
    for d in sort(result.violations; by = diag_sort_key)
        push!(lines, JSON.json(DiagnosticRecord(d)))
    end
    push!(lines, JSON.json(SummaryRecord(result)))
    return join(lines, '\n') * '\n'
end
