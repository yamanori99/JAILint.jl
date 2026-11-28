const _DIFF_POLICY_FORBIDDEN = "POLICY_BASE_FORBIDDEN"

@testset "diff policy from base ref" begin

    function strict_cfg()
        ver = string(pkgversion(AgentRuleLint))
        return """
        agentrulelint_version = \"=$(ver)\"

        [[project_rules]]
        id = \"policy-src\"
        level = \"deny\"
        paths = [\"**\"]
        forbid_literals = [\"$_DIFF_POLICY_FORBIDDEN\"]
        intent = \"\"
        do_not = \"\"
        """
    end

    function relaxed_cfg()
        ver = string(pkgversion(AgentRuleLint))
        return """
        agentrulelint_version = \"=$(ver)\"

        [[project_rules]]
        id = \"policy-src\"
        level = \"allow\"
        paths = [\"**\"]
        forbid_literals = [\"$_DIFF_POLICY_FORBIDDEN\"]
        intent = \"\"
        do_not = \"\"
        """
    end

    function policy_hits(res)
        return filter(
            d -> d.rule_id == "project/policy-src" && !d.suppressed,
            res.violations,
        )
    end

    @testset "base policy enforced under diff (API and CLI)" begin
        dir = abspath(mktempdir())
        try
            init_git_repo!(dir)
            write(joinpath(dir, ".AgentRuleLint.jl.toml"), strict_cfg())
            write(joinpath(dir, "t.jl"), "x = 1\n")
            git_commit_all!(dir, "strict base")
            write(joinpath(dir, ".AgentRuleLint.jl.toml"), relaxed_cfg())
            write(joinpath(dir, "t.jl"), "x = \"$_DIFF_POLICY_FORBIDDEN\"\n")
            git_commit_all!(dir, "relaxed config at HEAD")
            cd(dir) do
                res = AgentRuleLint.check(dir; diff_base = "HEAD^1")
                @test length(policy_hits(res)) == 1
                human = AgentRuleLint.format_human(
                    res;
                    root = dir,
                    io = IOContext(IOBuffer(), :color => false),
                )
                @test res.config_source.kind == AgentRuleLint.ConfigSourceKind.GIT_REF
                @test res.config_source.ref == "HEAD^1"
                code = AgentRuleLint.cli_main(["check", "--diff", "HEAD^1", "--format", "human"])
                @test code == res.exit_code
                res_wt = AgentRuleLint.check(dir; diff_base = "HEAD^1", worktree_config = true)
                @test !any(
                    d ->
                        d.rule_id == "project/policy-src" &&
                            d.level == AgentRuleLint.Level.DENY && !d.suppressed,
                    res_wt.violations,
                )
            end
        finally
            rm(dir, recursive = true, force = true)
        end
    end

    @testset "base without config uses builtin and prints notice" begin
        dir = abspath(mktempdir())
        try
            init_git_repo!(dir)
            write(joinpath(dir, "t.jl"), "x = 1\n")
            git_commit_all!(dir, "no config at base")
            write(joinpath(dir, ".AgentRuleLint.jl.toml"), strict_cfg())
            write(joinpath(dir, "t.jl"), "x = \"$_DIFF_POLICY_FORBIDDEN\"\n")
            git_commit_all!(dir, "config only at HEAD")
            write(joinpath(dir, ".AgentRuleLint.jl.toml"), strict_cfg())
            cd(dir) do
                res = AgentRuleLint.check(dir; diff_base = "HEAD^1")
                @test res.config_source.kind == AgentRuleLint.ConfigSourceKind.BUILTIN
                notice = res.config_notice
                @test occursin("HEAD^1", notice)
                @test occursin("built-in policy", notice)
                human = AgentRuleLint.format_human(res; root = dir, io = IOContext(IOBuffer(), :color => false))
                @test occursin(notice, human)
                agent = AgentRuleLint.format_agent(res; root = dir, io = IOContext(IOBuffer(), :color => false))
                @test occursin(notice, agent)
                json_out = tempname()
                err_path = tempname()
                try
                    open(err_path, "w") do err_io
                        code = redirect_stderr(err_io) do
                            AgentRuleLint.cli_main([
                                "check",
                                "--diff",
                                "HEAD^1",
                                "--format",
                                "json",
                                "--output",
                                json_out,
                                "t.jl",
                            ])
                        end
                        @test code == res.exit_code
                    end
                    @test occursin(notice, read(err_path, String))
                    @test !occursin(notice, read(json_out, String))
                finally
                    rm(json_out, force = true)
                    rm(err_path, force = true)
                end
            end
        finally
            rm(dir, recursive = true, force = true)
        end
    end

    @testset "worktree-config conflicts exit 2" begin
        @test AgentRuleLint.cli_main(["check", "--diff", "--worktree-config", "--config-from", "HEAD"]) == 2
        @test AgentRuleLint.cli_main([
            "check",
            "--diff",
            "--worktree-config",
            "--config",
            ".AgentRuleLint.jl.toml",
        ]) == 2
        @test_throws ArgumentError AgentRuleLint.validate_policy_source_kwargs(;
            worktree_config = true,
            config_from = "HEAD",
        )
    end

    @testset "missing diff base fails closed" begin
        dir = abspath(mktempdir())
        try
            init_git_repo!(dir)
            write(joinpath(dir, ".AgentRuleLint.jl.toml"), strict_cfg())
            write(joinpath(dir, "t.jl"), "1\n")
            git_commit_all!(dir, "only")
            cd(dir) do
                err = @test_throws AgentRuleLint.GitError AgentRuleLint.check(
                    dir;
                    diff_base = "not-a-real-ref",
                )
                @test occursin("not-a-real-ref", sprint(showerror, err.value))
                @test AgentRuleLint.exit_code_for_error(err.value) == 2
                @test AgentRuleLint.cli_main(["check", "--diff", "not-a-real-ref"]) == 2
            end
        finally
            rm(dir, recursive = true, force = true)
        end
    end
end
