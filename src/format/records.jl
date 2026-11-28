using JSON: JSON, JSONStyle, StructUtils

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

StructUtils.lower(::JSONStyle, x::Origin.T) = wire_name(x)
StructUtils.lower(::JSONStyle, x::Level.T) = wire_name(x)
StructUtils.lower(::JSONStyle, x::ExpectStatus.T) = wire_name(x)
