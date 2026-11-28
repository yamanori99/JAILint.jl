using JSON: JSON, JSONStyle, StructUtils

"""`config_source` object in JSON header records (optional keys omitted, not null)."""
struct ConfigSourceRecord
    kind::ConfigSourceKind.T
    path::Union{Nothing, String}
    ref::Union{Nothing, String}
    sha::Union{Nothing, String}
end

function ConfigSourceRecord(cs::ConfigSource)
    path = isempty(cs.path) ? nothing : cs.path
    ref = isempty(cs.ref) ? nothing : cs.ref
    sha = isempty(cs.sha) ? nothing : cs.sha
    return ConfigSourceRecord(cs.kind, path, ref, sha)
end

"""JSONL `header` object (field order matches sorted JSON key order)."""
struct HeaderRecord
    config_source::ConfigSourceRecord
    git_executable::String
    git_version::String
    julia_version::String
    parser::String
    position_encoding::String
    type::String
    version::String
end

function HeaderRecord(result::CheckResult)
    return HeaderRecord(
        ConfigSourceRecord(result.config_source),
        result.git_executable,
        result.git_version,
        string(VERSION),
        parser_rev_string(),
        "utf8-codepoint-1based",
        "header",
        string(AGENTRULELINT_VERSION),
    )
end

"""JSONL `summary` object (field order matches sorted JSON key order)."""
struct SummaryRecord
    complete::Bool
    exit_code::Int
    rules::Int
    suppressed::Int
    threshold::Level.T
    threshold_source::SeveritySource.T
    type::String
    violations::Int
end

function SummaryRecord(result::CheckResult)
    n_rules = length(unique(d.rule_id for d in active_violations(result.violations)))
    return SummaryRecord(
        result.complete,
        result.exit_code,
        n_rules,
        result.suppressed_count,
        result.exit_severity,
        result.exit_severity_source,
        "summary",
        result.violation_count,
    )
end

"""`agentrulelint report` JSON header line (field order matches sorted JSON key order)."""
struct ReportHeaderRecord
    agentrulelint_version::String
    julia_version::String
    parser::String
    position_encoding::String
    type::String
end

function ReportHeaderRecord()
    return ReportHeaderRecord(
        string(AGENTRULELINT_VERSION),
        string(VERSION),
        parser_rev_string(),
        "utf8-codepoint-1based",
        "header",
    )
end

"""`agentrulelint report` JSON rule_id line."""
struct ReportRuleIdRecord
    rule_id::String
end

"""`agentrulelint report` JSON fingerprint/snippet line (field order matches sorted JSON key order)."""
struct ReportSnippetRecord
    fingerprint::String
    pattern_hash::String
    snippet::String
end

"""Span object in JSON diagnostic records (field order matches sorted JSON key order)."""
struct SpanRecord
    end_col::Int
    end_line::Int
    start_col::Int
    start_line::Int
end

SpanRecord(s::Span) = SpanRecord(s.end_col, s.end_line, s.start_col, s.start_line)

"""One JSONL `diagnostic` object (field order matches sorted JSON key order)."""
struct DiagnosticRecord
    anchor_line::Int
    expect_status::ExpectStatus.T
    fingerprint::String
    level::Level.T
    message::String
    origin::Origin.T
    path::String
    rule_id::String
    span::SpanRecord
    suppressed::Bool
    type::String
end

function DiagnosticRecord(d::Violation)::DiagnosticRecord
    return DiagnosticRecord(
        d.anchor_line,
        d.expect_status,
        d.fingerprint,
        d.level,
        d.message,
        d.origin,
        d.path,
        d.rule_id,
        SpanRecord(d.span),
        d.suppressed,
        "diagnostic",
    )
end

function StructUtils.lower(::JSONStyle, cs::ConfigSourceRecord)
    nt = (kind = wire_name(cs.kind),)
    cs.path === nothing || (nt = merge(nt, (path = cs.path,)))
    cs.ref === nothing || (nt = merge(nt, (ref = cs.ref,)))
    cs.sha === nothing || (nt = merge(nt, (sha = cs.sha,)))
    return nt
end

StructUtils.lower(::JSONStyle, x::ConfigSourceKind.T) = wire_name(x)
StructUtils.lower(::JSONStyle, x::Origin.T) = wire_name(x)
StructUtils.lower(::JSONStyle, x::Level.T) = wire_name(x)
StructUtils.lower(::JSONStyle, x::ExpectStatus.T) = wire_name(x)
StructUtils.lower(::JSONStyle, x::SeveritySource.T) = wire_name(x)
