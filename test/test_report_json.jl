using AgentRuleLint
using JSON
using Test

const REPORT_GOLDEN_PATH = joinpath(ROOT, "test", "goldens", "report", "format_report.txt")
const REPORT_GOLDEN_PARSER_PLACEHOLDER = "<PARSER>"
const REPORT_GOLDEN_JULIA_PLACEHOLDER = "<JULIA_VERSION>"

"""Normalize `format_report` output for golden comparison (ec7228e baseline)."""
function _normalize_report_output(text::AbstractString)
    t = String(text)
    t = replace(t, string(AgentRuleLint.AGENTRULELINT_VERSION) => OUTPUT_GOLDEN_VERSION_PLACEHOLDER)
    t = replace(t, string(VERSION) => REPORT_GOLDEN_JULIA_PLACEHOLDER)
    t = replace(t, AgentRuleLint.parser_rev_string() => REPORT_GOLDEN_PARSER_PLACEHOLDER)
    return t
end

function _assert_report_json_line(line::AbstractString)
    obj = JSON.parse(line)
    roundtrip = JSON.json(obj)
    line == roundtrip || error("JSON round-trip mismatch:\n$line\n$roundtrip")
    return obj
end

@testset "report JSON via JSON.jl" begin
    @testset "byte match pinned golden (main ec7228e baseline)" begin
        d = AgentRuleLint.Violation(
            "project/no-internal-codename",
            AgentRuleLint.Origin.PROJECT,
            AgentRuleLint.Level.DENY,
            "test/corpus/split_string.jl",
            AgentRuleLint.Span(1, 1, 1, 10),
            1,
            "v1:abc",
            AgentRuleLint.ExpectStatus.NONE,
            false,
            "forbidden",
            "",
            "",
        )
        got = _normalize_report_output(
            AgentRuleLint.format_report(d.fingerprint, d, "secret = \"x\"\n"),
        )
        want = read(REPORT_GOLDEN_PATH, String)
        @test got == want
    end

    @testset "control characters in snippet line" begin
        src = "x = 1 # café" * string(Char(0x1F)) * "\n"
        d = AgentRuleLint.Violation(
            "r",
            AgentRuleLint.Origin.AGENTRULELINT,
            AgentRuleLint.Level.WARN,
            "x.jl",
            AgentRuleLint.Span(1, 1, 1, 20),
            1,
            "v1:" * repeat("b", 40),
            AgentRuleLint.ExpectStatus.NONE,
            false,
            "m",
            "",
            "",
        )
        out = AgentRuleLint.format_report(d.fingerprint, d, src)
        for line in split(strip(out), '\n'; keepempty = false)
            _assert_report_json_line(line)
        end
        payload = JSON.parse(split(strip(out), '\n'; keepempty = false)[3])
        snip = String(payload["snippet"])
        @test occursin("café", snip)
        @test occursin(string(Char(0x1F)), snip)
    end
end
