module SeveritySourceMisspellProbe
    using AgentRuleLint
    probe() = getproperty(AgentRuleLint.SeveritySource, :DEFALT)
end

@testset "SeveritySource enum" begin
    @testset "misspelled member raises UndefVarError in a test module" begin
        err = @test_throws UndefVarError SeveritySourceMisspellProbe.probe()
        @test err.value isa UndefVarError
    end

    @testset "wire_name spellings match JSON threshold_source field" begin
        @test collect(AgentRuleLint.wire_name.(instances(AgentRuleLint.SeveritySource.T))) ==
            ["default", "config", "cli"]
        for x in instances(AgentRuleLint.SeveritySource.T)
            @test AgentRuleLint.wire_name(x) == lowercase(String(Symbol(x)))
        end
    end
end

@testset "CheckResult below_threshold invariant" begin
    v = AgentRuleLint.Violation(
        "agentrulelint/test",
        AgentRuleLint.Origin.AGENTRULELINT,
        AgentRuleLint.Level.WARN,
        "x.jl",
        AgentRuleLint.Span(1, 1, 1, 1),
        1,
        "fp",
        AgentRuleLint.ExpectStatus.NONE,
        false,
        "m",
        "i",
        "d",
    )
    base_args = ([v], true, 0, AgentRuleLint.ConfigSource(), AgentRuleLint.OutputFormat.HUMAN, 20, 0, 0)

    @testset "count zero" begin
        AgentRuleLint.CheckResult(base_args...)
        for kw in (
                (below_threshold_count = 0, below_threshold_level = AgentRuleLint.Level.WARN),
                (below_threshold_count = 0, below_threshold_mixed = true),
            )
            err = @test_throws AgentRuleLint.InternalError AgentRuleLint.CheckResult(base_args...; kw...)
            @test AgentRuleLint.exit_code_for_error(err.value) == 3
        end
    end

    @testset "homogeneous below threshold" begin
        AgentRuleLint.CheckResult(
            base_args...;
            below_threshold_count = 2,
            below_threshold_level = AgentRuleLint.Level.WARN,
        )
        err = @test_throws AgentRuleLint.InternalError AgentRuleLint.CheckResult(
            base_args...;
            below_threshold_count = 2,
            below_threshold_level = nothing,
        )
        @test AgentRuleLint.exit_code_for_error(err.value) == 3
    end

    @testset "mixed below threshold" begin
        AgentRuleLint.CheckResult(
            base_args...;
            below_threshold_count = 2,
            below_threshold_mixed = true,
        )
        err = @test_throws AgentRuleLint.InternalError AgentRuleLint.CheckResult(
            base_args...;
            below_threshold_count = 2,
            below_threshold_mixed = true,
            below_threshold_level = AgentRuleLint.Level.WARN,
        )
        @test AgentRuleLint.exit_code_for_error(err.value) == 3
    end
end
