using AgentRuleLint
using Test

# Header JSON first lines from `format_json` on ec7228e (hand `_json_val`), placeholders for runtime fields.
const _MAIN_HEADER_BUILTIN =
    "{\"config_source\":{\"kind\":\"builtin\"},\"git_executable\":\"GIT\",\"git_version\":\"GV\",\"julia_version\":\"JVER\",\"parser\":\"PARSER\",\"position_encoding\":\"utf8-codepoint-1based\",\"type\":\"header\",\"version\":\"VER\"}"
const _MAIN_HEADER_PATH =
    "{\"config_source\":{\"kind\":\"path\",\"path\":\".AgentRuleLint.jl.toml\"},\"git_executable\":\"GIT\",\"git_version\":\"GV\",\"julia_version\":\"JVER\",\"parser\":\"PARSER\",\"position_encoding\":\"utf8-codepoint-1based\",\"type\":\"header\",\"version\":\"VER\"}"
const _MAIN_HEADER_GIT_REF =
    "{\"config_source\":{\"kind\":\"git_ref\",\"path\":\".AgentRuleLint.jl.toml\",\"ref\":\"origin/main\",\"sha\":\"abc1234567890abcdef0123456789abcdef0123456\"},\"git_executable\":\"GIT\",\"git_version\":\"GV\",\"julia_version\":\"JVER\",\"parser\":\"PARSER\",\"position_encoding\":\"utf8-codepoint-1based\",\"type\":\"header\",\"version\":\"VER\"}"

function _normalize_check_header_line(line::AbstractString)
    t = String(line)
    t = replace(t, string(AgentRuleLint.AGENTRULELINT_VERSION) => "VER")
    t = replace(t, string(VERSION) => "JVER")
    t = replace(t, AgentRuleLint.parser_rev_string() => "PARSER")
    return t
end

function _header_line(result::AgentRuleLint.CheckResult)
    return first(split(AgentRuleLint.format_json(result), '\n'; keepempty = false))
end

@testset "check JSON header config_source (ec7228e bytes)" begin
    v = AgentRuleLint.Violation(
        "r",
        AgentRuleLint.Origin.AGENTRULELINT,
        AgentRuleLint.Level.WARN,
        "x.jl",
        AgentRuleLint.Span(1, 1, 1, 1),
        1,
        "v1:" * repeat("a", 40),
        AgentRuleLint.ExpectStatus.NONE,
        false,
        "m",
        "",
        "",
    )

    @testset "builtin" begin
        cs = AgentRuleLint.ConfigSource(AgentRuleLint.ConfigSourceKind.BUILTIN, "", "", "")
        res = AgentRuleLint.CheckResult(
            [v],
            true,
            0,
            cs,
            AgentRuleLint.OutputFormat.JSON,
            20,
            0,
            0;
            git_executable = "GIT",
            git_version = "GV",
        )
        @test _normalize_check_header_line(_header_line(res)) == _MAIN_HEADER_BUILTIN
    end

    @testset "path" begin
        cs = AgentRuleLint.ConfigSource(
            AgentRuleLint.ConfigSourceKind.PATH,
            ".AgentRuleLint.jl.toml",
            "",
            "",
        )
        res = AgentRuleLint.CheckResult(
            [v],
            true,
            0,
            cs,
            AgentRuleLint.OutputFormat.JSON,
            20,
            0,
            0;
            git_executable = "GIT",
            git_version = "GV",
        )
        @test _normalize_check_header_line(_header_line(res)) == _MAIN_HEADER_PATH
    end

    @testset "git_ref with path ref sha" begin
        cs = AgentRuleLint.ConfigSource(
            AgentRuleLint.ConfigSourceKind.GIT_REF,
            ".AgentRuleLint.jl.toml",
            "origin/main",
            "abc1234567890abcdef0123456789abcdef0123456",
        )
        res = AgentRuleLint.CheckResult(
            [v],
            true,
            0,
            cs,
            AgentRuleLint.OutputFormat.JSON,
            20,
            0,
            0;
            git_executable = "GIT",
            git_version = "GV",
        )
        @test _normalize_check_header_line(_header_line(res)) == _MAIN_HEADER_GIT_REF
    end
end
