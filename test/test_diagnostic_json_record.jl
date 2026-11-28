using AgentRuleLint
using JSON
using Test

const _GOLDEN_JSON = joinpath(ROOT, "test", "goldens", "output", "check_json.txt")

function _diagnostic_keys_from_golden(path::AbstractString)
    for line in split(read(path, String), '\n'; keepempty = false)
        obj = JSON.parse(line; dicttype = Dict{String, Any})
        String(obj["type"]) == "diagnostic" || continue
        return collect(String, sort(keys(obj)))
    end
    error("no diagnostic line in $path")
end

function _span_keys_from_golden(path::AbstractString)
    for line in split(read(path, String), '\n'; keepempty = false)
        obj = JSON.parse(line; dicttype = Dict{String, Any})
        String(obj["type"]) == "diagnostic" || continue
        span = obj["span"]
        span isa Dict || error("expected span object")
        return collect(String, sort(keys(span)))
    end
    error("no diagnostic line in $path")
end

@testset "diagnostic JSON record contract" begin
    @testset "record fields match golden keys" begin
        golden_keys = _diagnostic_keys_from_golden(_GOLDEN_JSON)
        record_keys = String.(fieldnames(AgentRuleLint.DiagnosticRecord))
        @test sort(collect(record_keys)) == golden_keys
        span_keys = _span_keys_from_golden(_GOLDEN_JSON)
        @test sort(collect(String.(fieldnames(AgentRuleLint.SpanRecord)))) == span_keys
    end

    @testset "golden parity rejects field drift" begin
        golden_keys = Set(_diagnostic_keys_from_golden(_GOLDEN_JSON))
        record_keys = Set(String.(fieldnames(AgentRuleLint.DiagnosticRecord)))
        @test record_keys == golden_keys
        extra = setdiff(record_keys, golden_keys)
        missing = setdiff(golden_keys, record_keys)
        @test isempty(extra)
        @test isempty(missing)
    end

    @testset "diagnostic line bytes match record serializer" begin
        line = first(
            l for l in split(read(_GOLDEN_JSON, String), '\n'; keepempty = false) if
                occursin("\"type\":\"diagnostic\"", replace(l, " " => ""))
        )
        obj = JSON.parse(line; dicttype = Dict{String, Any})
        span = obj["span"]
        origin = only(
            o for o in instances(AgentRuleLint.Origin.T) if
                AgentRuleLint.wire_name(o) == String(obj["origin"])
        )
        level = only(
            l for l in instances(AgentRuleLint.Level.T) if
                AgentRuleLint.wire_name(l) == String(obj["level"])
        )
        expect = only(
            e for e in instances(AgentRuleLint.ExpectStatus.T) if
                AgentRuleLint.wire_name(e) == String(obj["expect_status"])
        )
        d = AgentRuleLint.Violation(
            String(obj["rule_id"]),
            origin,
            level,
            String(obj["path"]),
            AgentRuleLint.Span(
                span["start_line"],
                span["start_col"],
                span["end_line"],
                span["end_col"],
            ),
            obj["anchor_line"],
            String(obj["fingerprint"]),
            expect,
            obj["suppressed"],
            String(obj["message"]),
            "",
            "",
        )
        got = JSON.json(AgentRuleLint.DiagnosticRecord(d))
        @test got == line
    end
end
