SCOPE_RULE = "scope-paths"

@testset "scope-paths and --allow-paths" begin
    scope_root = dirname(@__DIR__)

    function minimal_cfg()
        ver = string(pkgversion(AgentRuleLint))
        return """
        agentrulelint_version = \"=$(ver)\"
        """
    end

    function scope_hits(res)
        return filter(
            d ->
            d.rule_id == SCOPE_RULE && !d.suppressed &&
                d.expect_status != AgentRuleLint.ExpectStatus.FULFILLED && d.level != AgentRuleLint.Level.ALLOW,
            res.violations,
        )
    end

    @testset "allow-paths without diff fails closed" begin
        cd(scope_root) do
            @test_throws AgentRuleLint.ConfigError AgentRuleLint.check(
                pwd();
                allow_paths = AgentRuleLint.compile_allow_path_globs(["src/**"]),
            )
            @test AgentRuleLint.cli_main(["check", "--allow-paths", "src/**"]) == 2
        end
    end

    @testset "empty allow-paths usage error" begin
        @test_throws AgentRuleLint.ConfigError AgentRuleLint.parse_allow_paths_cli("   ")
        @test_throws AgentRuleLint.ConfigError AgentRuleLint.parse_allow_paths_cli(", ,")
        @test_throws AgentRuleLint.ConfigError AgentRuleLint.compile_allow_path_globs(["/abs"])
    end

    @testset "duplicate --allow-paths is usage error" begin
        cd(scope_root) do
            @test AgentRuleLint.cli_main(
                [
                    "check",
                    "--allow-paths",
                    "src/**",
                    "--allow-paths",
                    "doc/**",
                ],
            ) == 2
            @test AgentRuleLint.cli_main(["check", "--allow-paths=src/**", "--allow-paths=doc/**"]) == 2
        end
    end

    function _julia_scope_probe(root::AbstractString, mode::AbstractString)
        proj = scope_root
        script = tempname() * ".jl"
        try
            write(
                script,
                """
                using AgentRuleLint
                root = ARGS[1]
                mode = ARGS[2]
                runner = joinpath(dirname(pathof(AgentRuleLint)), "runner.jl")
                Core.eval(
                    AgentRuleLint,
                    :(function run_check(r::AbstractString; kwargs...)
                        throw(ArgumentError("synthetic in-pipeline bug"))
                    end),
                )
                try
                    if mode == "check"
                        try
                            AgentRuleLint.check(root)
                            exit(11)
                        catch err
                            err isa AgentRuleLint.InternalError ? exit(0) : rethrow(err)
                        end
                    elseif mode == "cli"
                        code = cd(root) do
                            AgentRuleLint.cli_main(["check"])
                        end
                        exit(code == 3 ? 0 : 12)
                    else
                        exit(13)
                    end
                finally
                    Core.eval(AgentRuleLint, :(include(\$runner)))
                end
                """,
            )
            cmd = `$(Base.julia_cmd()) --startup-file=no --project=$proj $script $root $mode`
            return run(cmd)
        finally
            rm(script, force = true)
        end
    end

    @testset "stray ArgumentError in pipeline maps to internal error" begin
        root = scope_root
        @test _julia_scope_probe(root, "check").exitcode == 0
        @test _julia_scope_probe(root, "cli").exitcode == 0
    end

    @testset "invalid allow_paths keyword type is config fail-closed" begin
        @test_throws AgentRuleLint.ConfigError AgentRuleLint.check(scope_root; allow_paths = 123)
    end

    @testset "missing scope-paths rule is internal error" begin
        base = AgentRuleLint.resolve_policy(scope_root)
        policy = AgentRuleLint.PolicyBundle(
            base.agentrulelint_version,
            base.default_format,
            base.exit_severity,
            base.exit_severity_source,
            base.max_hits_per_rule,
            base.presets,
            Dict{String, AgentRuleLint.RuleSpec}(),
            base.project_rules,
            base.on_allow_rule,
            base.shell_safety,
            base.unsafe_boundary,
            base.unsafe_boundary_strict,
            base.config_path,
            base.config_source,
            base.project_toml_policy,
            base.protected_path_globs,
        )
        ev = AgentRuleLint.DiffPathEvent('M', "src/x.jl", "")
        allow = AgentRuleLint.compile_allow_path_globs(["src/**"])
        @test_throws AgentRuleLint.InternalError AgentRuleLint.enforce_scope_paths([ev], allow, policy)
    end

    @testset "in-scope diff passes" begin
        dir = abspath(mktempdir())
        try
            init_git_repo!(dir)
            write(joinpath(dir, ".AgentRuleLint.jl.toml"), minimal_cfg())
            mkpath(joinpath(dir, "src"))
            write(joinpath(dir, "src", "ok.jl"), "1\n")
            git_commit_all!(dir, "base")
            write(joinpath(dir, "src", "ok.jl"), "2\n")
            git_commit_all!(dir, "change")
            cd(dir) do
                res = AgentRuleLint.check(dir; diff_base = "HEAD^1", allow_paths = ["src/**"])
                @test isempty(scope_hits(res))
            end
        finally
            rm(dir, recursive = true, force = true)
        end
    end

    @testset "out-of-scope diff fails" begin
        dir = abspath(mktempdir())
        try
            init_git_repo!(dir)
            write(joinpath(dir, ".AgentRuleLint.jl.toml"), minimal_cfg())
            write(joinpath(dir, "secret.txt"), "a\n")
            git_commit_all!(dir, "base")
            write(joinpath(dir, "secret.txt"), "b\n")
            git_commit_all!(dir, "change")
            cd(dir) do
                res = AgentRuleLint.check(dir; diff_base = "HEAD^1", allow_paths = ["src/**"])
                hits = scope_hits(res)
                @test length(hits) == 1
                @test first(hits).path == "secret.txt"
            end
        finally
            rm(dir, recursive = true, force = true)
        end
    end

    @testset "rename outside allowlist" begin
        dir = abspath(mktempdir())
        try
            init_git_repo!(dir)
            write(joinpath(dir, ".AgentRuleLint.jl.toml"), minimal_cfg())
            write(joinpath(dir, ".JETLSConfig.toml"), "1\n")
            git_commit_all!(dir, "base")
            mv(joinpath(dir, ".JETLSConfig.toml"), joinpath(dir, "moved.toml"))
            git_commit_all!(dir, "rename")
            cd(dir) do
                res = AgentRuleLint.check(dir; diff_base = "HEAD^1", allow_paths = ["src/**"])
                paths = Set(h.path for h in scope_hits(res))
                @test ".JETLSConfig.toml" in paths || "moved.toml" in paths
            end
        finally
            rm(dir, recursive = true, force = true)
        end
    end

    @testset "corpus adversarial fixture present" begin
        @test isfile(joinpath(@__DIR__, "corpus", "scope_paths_outside_allow.jl"))
    end

end
