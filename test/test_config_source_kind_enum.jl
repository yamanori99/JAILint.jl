module ConfigSourceKindMisspellProbe
    using AgentRuleLint
    probe() = getproperty(AgentRuleLint.ConfigSourceKind, :GITREF)
end

@testset "ConfigSourceKind enum" begin
    @testset "misspelled member raises UndefVarError in a test module" begin
        err = @test_throws UndefVarError ConfigSourceKindMisspellProbe.probe()
        @test err.value isa UndefVarError
    end

    @testset "wire_name spellings match JSON config_source kind field" begin
        @test collect(AgentRuleLint.wire_name.(instances(AgentRuleLint.ConfigSourceKind.T))) ==
            ["builtin", "path", "git_ref"]
        for x in instances(AgentRuleLint.ConfigSourceKind.T)
            @test AgentRuleLint.wire_name(x) == lowercase(String(Symbol(x)))
        end
    end

    @testset "config_source_dict uses wire_name for kind" begin
        cs = AgentRuleLint.ConfigSource(AgentRuleLint.ConfigSourceKind.PATH, "cfg.toml", "", "")
        d = AgentRuleLint.config_source_dict(cs)
        @test d["kind"] == "path"
        @test d["path"] == "cfg.toml"
    end

    @testset "human_policy_banner base is distinct per kind" begin
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
        banners = String[]
        for (k, path, ref, sha) in (
                (AgentRuleLint.ConfigSourceKind.BUILTIN, "", "", ""),
                (AgentRuleLint.ConfigSourceKind.PATH, ".AgentRuleLint.jl.toml", "", ""),
                (AgentRuleLint.ConfigSourceKind.GIT_REF, "", "origin/main", "abc1234"),
            )
            cs = AgentRuleLint.ConfigSource(k, path, ref, sha)
            res = AgentRuleLint.CheckResult([v], true, 0, cs, AgentRuleLint.OutputFormat.HUMAN, 20, 0, 0)
            push!(
                banners,
                AgentRuleLint.config_source_base_label(res.config_source),
            )
        end
        @test length(unique(banners)) == length(banners)
        @test banners[1] == "builtin"
        @test banners[2] == ".AgentRuleLint.jl.toml"
        @test banners[3] == "origin/main"
    end
end
