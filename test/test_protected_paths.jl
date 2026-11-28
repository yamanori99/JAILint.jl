RULE = "protected-paths"

@testset "protected-paths" begin

    function base_cfg(extra = "")
        ver = string(pkgversion(AgentRuleLint))
        return """
        agentrulelint_version = \"=$(ver)\"

        [rules.protected-paths]
        level = \"forbid\"
        $extra
        """
    end

    function protected_hits(res)
        return filter(
            d ->
            d.rule_id == RULE && !d.suppressed &&
                d.expect_status != AgentRuleLint.ExpectStatus.FULFILLED && d.level != AgentRuleLint.Level.ALLOW,
            res.violations,
        )
    end

    @testset "no diff mode reports nothing" begin
        dir = abspath(mktempdir())
        try
            write(joinpath(dir, ".AgentRuleLint.jl.toml"), base_cfg())
            write(joinpath(dir, ".JETLSConfig.toml"), "x = 1\n")
            res = AgentRuleLint.check(dir)
            @test isempty(protected_hits(res))
        finally
            rm(dir, recursive = true, force = true)
        end
    end

    @testset "auto-protected JETLS modify" begin
        dir = abspath(mktempdir())
        try
            init_git_repo!(dir)
            write(joinpath(dir, ".AgentRuleLint.jl.toml"), base_cfg())
            write(joinpath(dir, ".JETLSConfig.toml"), "ok = true\n")
            git_commit_all!(dir, "base")
            write(joinpath(dir, ".JETLSConfig.toml"), "ok = false\n")
            git_commit_all!(dir, "change")
            cd(dir) do
                res = AgentRuleLint.check(dir; diff_base = "HEAD^1")
                hits = protected_hits(res)
                @test length(hits) == 1
                @test first(hits).path == ".JETLSConfig.toml"
                @test occursin("modified", first(hits).message)
                @test occursin("JETLS", first(hits).message)
            end
        finally
            rm(dir, recursive = true, force = true)
        end
    end

    @testset "user glob reason in message" begin
        dir = abspath(mktempdir())
        try
            init_git_repo!(dir)
            extra = """
            paths = [
              { glob = "docs/**", reason = "Docs require human review." },
            ]
            """
            write(joinpath(dir, ".AgentRuleLint.jl.toml"), base_cfg(extra))
            mkpath(joinpath(dir, "docs"))
            write(joinpath(dir, "docs", "note.txt"), "v1\n")
            git_commit_all!(dir, "base")
            write(joinpath(dir, "docs", "note.txt"), "v2\n")
            git_commit_all!(dir, "change")
            cd(dir) do
                res = AgentRuleLint.check(dir; diff_base = "HEAD^1")
                hits = protected_hits(res)
                @test any(h -> h.path == "docs/note.txt" && occursin("Docs require human review.", h.message), hits)
            end
        finally
            rm(dir, recursive = true, force = true)
        end
    end

    @testset "Project.toml semantic allow new dep" begin
        dir = abspath(mktempdir())
        try
            init_git_repo!(dir)
            write(joinpath(dir, ".AgentRuleLint.jl.toml"), base_cfg())
            write(
                joinpath(dir, "Project.toml"),
                """
                name = "Tmp"
                uuid = "11111111-1111-1111-1111-111111111111"
                version = "0.1.0"
                """,
            )
            git_commit_all!(dir, "base")
            write(
                joinpath(dir, "Project.toml"),
                """
                name = "Tmp"
                uuid = "11111111-1111-1111-1111-111111111111"
                version = "0.1.0"

                [deps]
                Test = "8dfed614-e22c-5e08-99e1-c55d7950c0ef"

                [compat]
                Test = "1"
                """,
            )
            git_commit_all!(dir, "add dep")
            cd(dir) do
                res = AgentRuleLint.check(dir; diff_base = "HEAD^1")
                @test isempty(protected_hits(res))
            end
        finally
            rm(dir, recursive = true, force = true)
        end
    end

    @testset "Project.toml semantic forbid sources" begin
        dir = abspath(mktempdir())
        try
            init_git_repo!(dir)
            write(joinpath(dir, ".AgentRuleLint.jl.toml"), base_cfg())
            write(
                joinpath(dir, "Project.toml"),
                """
                name = "Tmp"
                uuid = "11111111-1111-1111-1111-111111111111"
                version = "0.1.0"
                """,
            )
            git_commit_all!(dir, "base")
            append =
            """

            [sources]
            Foo = { git = "https://example.com/Foo.jl.git" }
            """
            write(joinpath(dir, "Project.toml"), read(joinpath(dir, "Project.toml"), String) * append)
            git_commit_all!(dir, "sources")
            cd(dir) do
                res = AgentRuleLint.check(dir; diff_base = "HEAD^1")
                @test !isempty(protected_hits(res))
            end
        finally
            rm(dir, recursive = true, force = true)
        end
    end

    @testset "rename both sides protected" begin
        dir = abspath(mktempdir())
        try
            init_git_repo!(dir)
            write(joinpath(dir, ".AgentRuleLint.jl.toml"), base_cfg())
            write(joinpath(dir, ".JETLSConfig.toml"), "1\n")
            git_commit_all!(dir, "base")
            # Use git mv so case-only renames work on case-insensitive filesystems
            # (default macOS APFS, many Windows volumes). Julia's mv fails there.
            run_git_cmd(dir, "mv", ".JETLSConfig.toml", ".jetlsconfig.toml"; cwd = dir)
            git_commit_all!(dir, "rename case")
            cd(dir) do
                events = AgentRuleLint.git_diff_path_events(dir, "HEAD^1")
                @test any(e -> e.status == 'R', events)
                res = AgentRuleLint.check(dir; diff_base = "HEAD^1")
                paths = Set(h.path for h in protected_hits(res))
                @test ".JETLSConfig.toml" in paths
            end
        finally
            rm(dir, recursive = true, force = true)
        end
    end

    @testset "ceilings monotonic decrease exempt" begin
        dir = abspath(mktempdir())
        try
            init_git_repo!(dir)
            write(joinpath(dir, ".AgentRuleLint.jl.toml"), base_cfg())
            mkpath(joinpath(dir, ".agentrulelint"))
            write(
                joinpath(dir, ".agentrulelint", "ceilings.toml"),
                """
                [violations."protected-paths"]
                "a.jl" = 2
                """,
            )
            git_commit_all!(dir, "base")
            write(
                joinpath(dir, ".agentrulelint", "ceilings.toml"),
                """
                [violations."protected-paths"]
                "a.jl" = 1
                """,
            )
            git_commit_all!(dir, "lower")
            cd(dir) do
                res = AgentRuleLint.check(dir; diff_base = "HEAD^1")
                @test !any(h -> h.path == ".agentrulelint/ceilings.toml", protected_hits(res))
            end
        finally
            rm(dir, recursive = true, force = true)
        end
    end

    @testset "ceilings increase violates" begin
        dir = abspath(mktempdir())
        try
            init_git_repo!(dir)
            write(joinpath(dir, ".AgentRuleLint.jl.toml"), base_cfg())
            mkpath(joinpath(dir, ".agentrulelint"))
            write(
                joinpath(dir, ".agentrulelint", "ceilings.toml"),
                """
                [violations."protected-paths"]
                "a.jl" = 1
                """,
            )
            git_commit_all!(dir, "base")
            write(
                joinpath(dir, ".agentrulelint", "ceilings.toml"),
                """
                [violations."protected-paths"]
                "a.jl" = 2
                """,
            )
            git_commit_all!(dir, "raise")
            cd(dir) do
                res = AgentRuleLint.check(dir; diff_base = "HEAD^1")
                @test any(h -> h.path == ".agentrulelint/ceilings.toml", protected_hits(res))
            end
        finally
            rm(dir, recursive = true, force = true)
        end
    end

    @testset "config self-disable bypass" begin
        dir = abspath(mktempdir())
        try
            init_git_repo!(dir)
            write(joinpath(dir, ".AgentRuleLint.jl.toml"), base_cfg())
            write(joinpath(dir, ".JETLSConfig.toml"), "ok = 1\n")
            git_commit_all!(dir, "base")
            ver = string(pkgversion(AgentRuleLint))
            bypass = """
            agentrulelint_version = \"=$(ver)\"

            [rules.protected-paths]
            level = \"allow\"
            """
            write(joinpath(dir, ".AgentRuleLint.jl.toml"), bypass)
            write(joinpath(dir, ".JETLSConfig.toml"), "ok = 2\n")
            git_commit_all!(dir, "bypass and jetls")
            cd(dir) do
                res = AgentRuleLint.check(dir; diff_base = "HEAD^1")
                hits = protected_hits(res)
                @test any(h -> h.path == ".AgentRuleLint.jl.toml", hits)
                @test any(h -> h.path == ".JETLSConfig.toml", hits)
                @test res.config_source.ref == "HEAD^1"
                err = try
                    AgentRuleLint.check(dir; diff_base = "HEAD^1", worktree_config = true)
                    nothing
                catch e
                    e
                end
                @test err isa AgentRuleLint.ConfigError
                @test occursin("must be forbid", sprint(showerror, err))
                @test AgentRuleLint.cli_main(["check", "--diff", "HEAD^1"]) != 0
            end
        finally
            rm(dir, recursive = true, force = true)
        end
    end

    @testset "rename Project.toml not semantically exempt" begin
        dir = abspath(mktempdir())
        try
            init_git_repo!(dir)
            write(joinpath(dir, ".AgentRuleLint.jl.toml"), base_cfg())
            write(
                joinpath(dir, "Project.toml"),
                """
                name = "Tmp"
                uuid = "11111111-1111-1111-1111-111111111111"
                version = "0.1.0"
                """,
            )
            git_commit_all!(dir, "base")
            mv(joinpath(dir, "Project.toml"), joinpath(dir, "proj.toml"))
            git_commit_all!(dir, "rename")
            cd(dir) do
                res = AgentRuleLint.check(dir; diff_base = "HEAD^1")
                paths = Set(h.path for h in protected_hits(res))
                @test "Project.toml" in paths || "proj.toml" in paths
            end
        finally
            rm(dir, recursive = true, force = true)
        end
    end

    @testset "rename ceilings.toml not exempt" begin
        dir = abspath(mktempdir())
        try
            init_git_repo!(dir)
            write(joinpath(dir, ".AgentRuleLint.jl.toml"), base_cfg())
            mkpath(joinpath(dir, ".agentrulelint"))
            write(
                joinpath(dir, ".agentrulelint", "ceilings.toml"),
                "[violations.\"protected-paths\"]\n\"x.jl\" = 1\n",
            )
            git_commit_all!(dir, "base")
            mv(
                joinpath(dir, ".agentrulelint", "ceilings.toml"),
                joinpath(dir, ".agentrulelint", "caps.toml"),
            )
            git_commit_all!(dir, "rename ceilings")
            cd(dir) do
                res = AgentRuleLint.check(dir; diff_base = "HEAD^1")
                @test !isempty(protected_hits(res))
            end
        finally
            rm(dir, recursive = true, force = true)
        end
    end

    @testset "legacy config filename stays auto-protected" begin
        legacy = AgentRuleLint.LEGACY_CONFIG_FILENAME
        @test legacy in AgentRuleLint.AUTO_PROTECTED_EXACT
        @test occursin("AgentRuleLint policy", AgentRuleLint.auto_protected_reason(legacy))
    end

    @testset "corpus fixtures" begin
        hit = joinpath(@__DIR__, "corpus", "protected_paths_jetls_evade.toml")
        @test isfile(hit)
        ok = joinpath(@__DIR__, "corpus", "protected_paths_dep_add.toml")
        @test isfile(ok)
    end

    @testset "mutation harness and shard selection (repository config)" begin
        protected_infra = (
            "test/mutation/mutation_lib.jl",
            "test/mutation/run_all_lib.jl",
            "test/mutation/run_all.jl",
            "test/shard_lib.jl",
            "test/shard_select.jl",
            "test/parallel_testsuite_config.jl",
        )
        repo_config = joinpath(ROOT, ".AgentRuleLint.jl.toml")
        @test isfile(repo_config)
        policy = AgentRuleLint.load_policy(ROOT; config_path = repo_config)
        for rel in protected_infra
            matched, reason = AgentRuleLint.classify_protected_path(rel, policy)
            @test matched
            @test !isempty(reason)
            ev = AgentRuleLint.DiffPathEvent('M', rel, "")
            diags = AgentRuleLint._handle_protected_event(ROOT, "HEAD^1", ev, policy)
            @test length(diags) == 1
            @test first(diags).rule_id == RULE
            @test first(diags).path == rel
            @test occursin("modified", first(diags).message)
            @test occursin(reason, first(diags).message)
        end
    end

end
