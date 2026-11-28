using AgentRuleLint
using JSON
using Test

# ROOT comes from ParallelTestRunner init_code in test/runtests.jl.

const SCHEMA_PATH = joinpath(ROOT, "schemas", "check-jsonl.schema.json")
const HUMAN_GOLDEN_PATH = joinpath(@__DIR__, "fixtures", "human_output_golden.txt")
const HUMAN_GOLDEN_CS =
    AgentRuleLint.ConfigSource(AgentRuleLint.ConfigSourceKind.GIT_REF, "", "origin/main", "9f2c1a4e")

function strip_ansi_local(s::AbstractString)
    return AgentRuleLint.strip_ansi(s)
end

function check_result_fixture()
    cs = AgentRuleLint.ConfigSource(AgentRuleLint.ConfigSourceKind.PATH, ".AgentRuleLint.jl.toml", "", "")
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
        "forbidden literal matched",
        "Keep internal codenames out of public package files.",
        "Do not split strings to evade.",
    )
    return AgentRuleLint.CheckResult([d], true, 1, cs, AgentRuleLint.OutputFormat.HUMAN, 20, 0, 1)
end

function human_fixture_result(paths::Vector{String})
    res = AgentRuleLint.check(ROOT; paths = paths)
    return AgentRuleLint.CheckResult(
        res.violations,
        res.complete,
        res.exit_code,
        HUMAN_GOLDEN_CS,
        res.default_format,
        res.max_hits_per_rule,
        res.suppressed_count,
        res.violation_count;
        ceilings = res.ceilings,
    )
end

function jsonl_record(line::AbstractString)::Dict{String, Any}
    return JSON.parse(line; dicttype = Dict{String, Any})
end

function validate_jsonl_schema!(text::AbstractString)
    JSON.parse(read(SCHEMA_PATH, String))
    lines = split(strip(text), '\n')
    length(lines) >= 2 || error("expected header, diagnostics, and summary lines")
    kinds = String[]
    for (i, line) in enumerate(lines)
        obj = jsonl_record(line)
        t = String(obj["type"])
        push!(kinds, t)
        if t == "header"
            @test obj["version"] isa AbstractString
            @test String(obj["position_encoding"]) == "utf8-codepoint-1based"
        elseif t == "diagnostic"
            @test haskey(obj, "rule_id")
            @test haskey(obj, "span")
        elseif t == "summary"
            @test obj["exit_code"] isa Integer
        else
            error("unknown record type $t at line $i")
        end
    end
    @test kinds[1] == "header"
    @test kinds[end] == "summary"
    return nothing
end

@testset "output formats and color" begin
    @testset "agent and json ignore IO color" begin
        res = check_result_fixture()
        plain_agent = AgentRuleLint.format_agent(res; root = ROOT, io = IOContext(IOBuffer(), :color => false))
        color_agent = AgentRuleLint.format_agent(res; root = ROOT, io = IOContext(IOBuffer(), :color => true))
        @test plain_agent == color_agent
        json_a = AgentRuleLint.format_json(res)
        json_b = AgentRuleLint.format_json(res)
        @test json_a == json_b
        @test !occursin("\e[", json_a)
    end

    @testset "human color strips to plain" begin
        res = check_result_fixture()
        plain = AgentRuleLint.format_human(res; root = ROOT, io = IOContext(IOBuffer(), :color => false))
        colored = AgentRuleLint.format_human(res; root = ROOT, io = IOContext(IOBuffer(), :color => true))
        @test strip_ansi_local(colored) == plain
        @test !occursin("\e[36m", colored)
        @test occursin("\e[31mError\e[39m", colored)
    end

    @testset "json schema validation" begin
        res = AgentRuleLint.check(ROOT; paths = [joinpath("test", "corpus", "split_string.jl")])
        js = AgentRuleLint.format_json(res)
        validate_jsonl_schema!(js)
        @test occursin("\"version\"", replace(js, " " => ""))
    end

    @testset "json formatter uses CheckResult only" begin
        corpus = joinpath("test", "corpus", "split_string.jl")
        res = AgentRuleLint.check(ROOT; paths = [corpus], config_from = "HEAD")
        json_here = AgentRuleLint.format_json(res)

        remote = mktempdir()
        try
            mkpath(joinpath(remote, "shadow"))
            json_there = cd(joinpath(remote, "shadow")) do
                AgentRuleLint.format_json(res)
            end
            @test json_here == json_there
        finally
            rm(remote; recursive = true, force = true)
        end

    end

    @testset "json diagnostic sort order" begin
        cs = AgentRuleLint.ConfigSource()
        z = AgentRuleLint.Violation(
            "r",
            AgentRuleLint.Origin.PROJECT,
            AgentRuleLint.Level.DENY,
            "z/z.jl",
            AgentRuleLint.Span(1, 1, 1, 1),
            1,
            "v1:z",
            AgentRuleLint.ExpectStatus.NONE,
            false,
            "z-msg",
            "",
            "",
        )
        a = AgentRuleLint.Violation(
            "r",
            AgentRuleLint.Origin.PROJECT,
            AgentRuleLint.Level.DENY,
            "a/a.jl",
            AgentRuleLint.Span(1, 1, 1, 1),
            1,
            "v1:a",
            AgentRuleLint.ExpectStatus.NONE,
            false,
            "a-msg",
            "",
            "",
        )
        res = AgentRuleLint.CheckResult([z, a], true, 1, cs, AgentRuleLint.OutputFormat.HUMAN, 20, 0, 2)
        paths = String[]
        for line in split(AgentRuleLint.format_json(res), '\n'; keepempty = false)
            obj = jsonl_record(line)
            String(obj["type"]) == "diagnostic" || continue
            push!(paths, String(obj["path"]))
        end
        @test paths == String["a/a.jl", "z/z.jl"]
    end

    @testset "explain and report exit codes" begin
        cd(ROOT) do
            @test AgentRuleLint.cli_main(["explain", "project/no-internal-codename"]) == 0
            @test AgentRuleLint.cli_main(["explain", "expect-audit"]) == 0
            @test AgentRuleLint.cli_main(["explain", "no-such-rule"]) == 2
            @test AgentRuleLint.cli_main(["explain", "protected-paths"]) == 0
        end
    end

    @testset "ceiling dash without ratchet file" begin
        res = AgentRuleLint.check(ROOT; paths = [joinpath("test", "corpus", "split_string.jl")])
        human = AgentRuleLint.format_human(res; root = ROOT, io = IOContext(IOBuffer(), :color => false))
        agent = AgentRuleLint.format_agent(res; root = ROOT, io = IOContext(IOBuffer(), :color => false))
        @test occursin("ceiling 0)", human)
        @test occursin("ceiling=-", agent)
    end

    @testset "human golden byte match" begin
        paths = [
            joinpath("test", "corpus", "block_expect.jl"),
            joinpath("test", "corpus", "split_string.jl"),
        ]
        res = human_fixture_result(paths)
        io = IOContext(IOBuffer(), :color => false)
        out = AgentRuleLint.format_human(res; root = ROOT, io = io, output_width = 100)
        expected = read(HUMAN_GOLDEN_PATH, String)
        @test _golden_normalize_text(out) == _golden_normalize_text(expected)
    end

    @testset "human non-TTY ignores COLUMNS for code gutter" begin
        res = human_fixture_result([joinpath("test", "corpus")])
        plain = IOContext(IOBuffer(), :color => false)
        out_narrow = AgentRuleLint.format_human(res; root = ROOT, io = plain)
        withenv("COLUMNS" => "60") do
            out_cols = AgentRuleLint.format_human(res; root = ROOT, io = plain)
            @test out_narrow == out_cols
        end
    end

    @testset "expect-audit blank line does not duplicate unused" begin
        res = AgentRuleLint.check(ROOT; paths = [joinpath("test", "corpus", "expect_blank_line.jl")])
        ea = filter(
            d -> d.rule_id == "expect-audit" && d.path == "test/corpus/expect_blank_line.jl",
            res.violations,
        )
        msgs = unique(d.message for d in ea)
        @test "unused expect" ∉ msgs
        @test any(m -> occursin("blank line breaking", m), msgs)
    end

    @testset "explain uses registry docs" begin
        audit = AgentRuleLint.explain_rule("expect-audit"; root = ROOT)
        @test occursin("agentrulelint-expect: expect-audit", audit)
        @test occursin("level: forbid", audit)
        paths = AgentRuleLint.explain_rule("protected-paths"; root = ROOT)
        @test occursin("rule_id: protected-paths", paths)
        @test occursin("Protect designated policy, lockfiles, and workflow paths", paths)
        @test occursin("Edit protected files, weaken compat, or rename paths", paths)
    end

    @testset "explain preserves main built-in reference text" begin
        main_anchor_phrases = Dict(
            "expect-audit" => [
                "First non-blank code line",
                "agentrulelint-expect:",
                "Suppresses only violations whose anchor_line matches",
            ],
            "unsafe-boundary" => [
                "Base.Meta.parse",
                "getfield",
                "`@eval`",
            ],
            "scope-paths" => ["--allow-paths", "--diff <base>", "level = \"forbid\""],
            "protected-paths" => [
                "project_toml_policy",
                "Manifest*.toml",
                "--diff <base>",
            ],
        )
        for (rid, phrases) in main_anchor_phrases
            text = AgentRuleLint.explain_rule(rid; root = ROOT)
            for p in phrases
                @test occursin(p, text)
            end
        end
        ub = AgentRuleLint.explain_rule("unsafe-boundary"; root = ROOT)
        @test occursin("allow_modules", ub)
        @test occursin("allow_globs", ub)
        @test occursin("[rules.unsafe-boundary]", ub)
        @test occursin("Remaining gaps:", ub)
        @test occursin("`Expr` escapes", ub)
        @test !occursin("@assume_effects", ub)
        ub_strict = AgentRuleLint.explain_rule("unsafe-boundary/strict"; root = ROOT)
        @test occursin("@assume_effects", ub_strict)
        @test occursin("unsafe-boundary/strict", ub_strict)
        @test occursin("Flag `@inbounds`", ub_strict)
        @test occursin("undefined behavior", ub_strict)
        @test occursin("core `unsafe-boundary`", ub_strict)
        expect = AgentRuleLint.explain_rule("expect-audit"; root = ROOT)
        @test occursin("Syntax:", expect)
        @test occursin("runic: off", expect)
    end

    @testset "preset intent/do_not fallback when config omits text" begin
        res = AgentRuleLint.check(ROOT; paths = [joinpath("test", "corpus", "unsafe_inbounds.jl")])
        strict = filter(
            d -> d.rule_id == "unsafe-boundary" && !d.suppressed,
            res.violations,
        )
        @test any(d -> occursin("@inbounds", d.message), strict)
        agent = AgentRuleLint.format_agent(res; root = ROOT)
        @test occursin("RULE [AgentRuleLint] unsafe-boundary", agent)
        @test occursin("intent: Keep runtime", agent)
        ub_explain = AgentRuleLint.explain_rule("unsafe-boundary/strict"; root = ROOT)
        @test occursin("Flag `@inbounds`", ub_explain)
        @test occursin("Rely on core `unsafe-boundary`", ub_explain)
        @test occursin("do_not:", ub_explain)
        @test occursin("intent:\nFlag `@inbounds`", ub_explain)
        @test occursin("do_not:\nRely on core `unsafe-boundary`", ub_explain)
        @test occursin("intent: Keep runtime", agent)
        @test occursin("do_not: Add allow_globs", agent)

        dir = mktempdir()
        try
            ver = string(pkgversion(AgentRuleLint))
            write(
                joinpath(dir, ".AgentRuleLint.jl.toml"),
                """
                agentrulelint_version = \"=$(ver)\"
                presets = [\"shell-safety\"]

                [rules.\"shell-safety/process-pattern\"]
                level = \"deny\"
                """,
            )
            shell = AgentRuleLint.explain_rule("shell-safety/process-pattern"; root = dir)
            @test occursin("pkill, killall, remote shells, sudo", shell)
            @test occursin("pk\" * \"ill", shell)
        finally
            rm(dir, recursive = true, force = true)
        end
    end
end
