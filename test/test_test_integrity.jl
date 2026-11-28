@testset "test-integrity rule" begin
    root = ROOT
    cfg = read(joinpath(root, ".AgentRuleLint.jl.toml"), String)

    function check_rel(rel)
        return AgentRuleLint.check(root; paths = [rel])
    end

    function ti_hits(rel)
        res = check_rel(rel)
        return filter(d -> d.rule_id == "test-integrity" && !d.suppressed, res.violations)
    end

    rel(p) = joinpath("test", "corpus", p)

    @testset "syntax mode detectors" begin
        trivial = ti_hits(rel("test_integrity_trivial_true.jl"))
        @test any(d -> occursin("trivially true", d.message), trivial)
        @test length(trivial) >= 2

        valid = ti_hits(rel("test_integrity_valid.jl"))
        @test isempty(valid)

        evasion = ti_hits(rel("test_integrity_const_fold.jl"))
        @test any(d -> occursin("trivially true", d.message), evasion)

        broad = ti_hits(rel("test_integrity_broad_throws.jl"))
        @test length(broad) >= 2
        @test all(d -> occursin("overly broad", d.message), broad)
    end

    @testset "explain uses policy registry only" begin
        out = cd(root) do
            AgentRuleLint.explain_rule("test-integrity")
        end
        @test occursin("intent:", out)
        @test occursin("do_not:", out)
        @test occursin("hollow or weakened tests", out)
        bad = abspath(mktempdir())
        try
            write(joinpath(bad, ".AgentRuleLint.jl.toml"), "agentrulelint_version = \"=99.99.99\"\n")
            cd(bad) do
                @test AgentRuleLint.cli_main(["explain", "test-integrity"]) == 2
            end
        finally
            rm(bad, recursive = true, force = true)
        end
    end

    @testset "diff: skip count and runtests removal" begin
        dir = abspath(mktempdir())
        try
            init_git_repo!(dir)
            write(joinpath(dir, ".AgentRuleLint.jl.toml"), cfg)
            mkpath(joinpath(dir, "test"))
            write(joinpath(dir, "test", "runtests.jl"), "include(\"case.jl\")\n")
            write(joinpath(dir, "test", "case.jl"), "@test 1 == 1\n")
            git_commit_all!(dir, "base")
            write(joinpath(dir, "test", "case.jl"), "@test 1 == 1\n@test_skip false\n")
            write(
                joinpath(dir, "test", "runtests.jl"),
                "# removed include\n",
            )
            git_commit_all!(dir, "weaken")
            cd(dir) do
                res = AgentRuleLint.check(dir; diff_base = "HEAD^1")
                hits = filter(d -> d.rule_id == "test-integrity" && !d.suppressed, res.violations)
                @test any(d -> occursin("test_skip count increased", d.message), hits)
                @test any(d -> occursin("removed from test/runtests.jl", d.message), hits)
            end
        finally
            rm(dir, recursive = true, force = true)
        end
    end

    @testset "diff: atol loosening" begin
        dir = abspath(mktempdir())
        try
            init_git_repo!(dir)
            write(joinpath(dir, ".AgentRuleLint.jl.toml"), cfg)
            mkpath(joinpath(dir, "test"))
            write(joinpath(dir, "test", "approx.jl"), "isapprox(1.0, 2.0; atol=1e-12)\n")
            git_commit_all!(dir, "base")
            write(joinpath(dir, "test", "approx.jl"), "isapprox(1.0, 2.0; atol=1e-3)\n")
            git_commit_all!(dir, "loose")
            cd(dir) do
                res = AgentRuleLint.check(dir; diff_base = "HEAD^1")
                hits = filter(d -> d.rule_id == "test-integrity" && !d.suppressed, res.violations)
                @test any(d -> occursin("tolerance loosened", d.message), hits)
            end
        finally
            rm(dir, recursive = true, force = true)
        end
    end

    @testset "exit and Base.exit in driver" begin
        dir = abspath(mktempdir())
        try
            write(joinpath(dir, ".AgentRuleLint.jl.toml"), cfg)
            mkpath(joinpath(dir, "test"))
            write(joinpath(dir, "test", "runtests.jl"), "include(\"early.jl\")\n")
            write(joinpath(dir, "test", "early.jl"), "Base.exit(0)\n@test true\n")
            res = AgentRuleLint.check(dir; paths = ["test"])
            hits = filter(d -> d.rule_id == "test-integrity" && occursin("exit", d.message), res.violations)
            @test !isempty(hits)
        finally
            rm(dir, recursive = true, force = true)
        end
    end

    @testset "mutation guard: trivial @test corpus" begin
        hits = ti_hits(rel("test_integrity_trivial_true.jl"))
        @test !isempty(hits)
    end

    @testset "named atol constant is a documented blind spot" begin
        @test isempty(ti_hits(rel("test_integrity_named_tol_limit.jl")))
    end

    @testset "diff: skip/broken in a newly added test file (base count 0)" begin
        dir = abspath(mktempdir())
        try
            init_git_repo!(dir)
            write(joinpath(dir, ".AgentRuleLint.jl.toml"), cfg)
            mkpath(joinpath(dir, "test"))
            write(joinpath(dir, "test", "runtests.jl"), "# empty\n")
            git_commit_all!(dir, "base")
            write(joinpath(dir, "test", "new_skip.jl"), "@test_broken false\n")
            write(joinpath(dir, "test", "runtests.jl"), "include(\"new_skip.jl\")\n")
            git_commit_all!(dir, "add file with skip")
            cd(dir) do
                res = AgentRuleLint.check(dir; diff_base = "HEAD^1")
                hits = filter(
                    d -> d.rule_id == "test-integrity" && occursin("test_broken count increased", d.message),
                    res.violations,
                )
                @test !isempty(hits)
                @test first(hits).path == "test/new_skip.jl"
            end
        finally
            rm(dir, recursive = true, force = true)
        end
    end

    @testset "diff: path events are fail-closed (unknown status)" begin
        @test_throws AgentRuleLint.GitError AgentRuleLint._parse_diff_path_events_payload("U\0weird\0")
    end

    @testset "diff: renamed test file without runtests update is flagged" begin
        dir = abspath(mktempdir())
        try
            init_git_repo!(dir)
            write(joinpath(dir, ".AgentRuleLint.jl.toml"), cfg)
            mkpath(joinpath(dir, "test"))
            write(joinpath(dir, "test", "runtests.jl"), "include(\"case.jl\")\n")
            write(joinpath(dir, "test", "case.jl"), "@test 1 == 1\n")
            git_commit_all!(dir, "base")
            run_git_cmd(dir, "mv", "test/case.jl", "test/renamed.jl"; cwd = dir)
            write(joinpath(dir, "test", "runtests.jl"), "include(\"case.jl\")\n")
            git_commit_all!(dir, "rename only")
            cd(dir) do
                res = AgentRuleLint.check(dir; diff_base = "HEAD^1")
                hits = filter(
                    d ->
                    d.rule_id == "test-integrity" &&
                        d.expect_status == AgentRuleLint.ExpectStatus.DELETED_TEST &&
                        d.path == "test/case.jl",
                    res.violations,
                )
                @test !isempty(hits)
            end
        finally
            rm(dir, recursive = true, force = true)
        end
    end

    @testset "diff: renamed test file with matching include update is allowed" begin
        dir = abspath(mktempdir())
        try
            init_git_repo!(dir)
            write(joinpath(dir, ".AgentRuleLint.jl.toml"), cfg)
            mkpath(joinpath(dir, "test"))
            write(joinpath(dir, "test", "runtests.jl"), "include(\"case.jl\")\n")
            write(joinpath(dir, "test", "case.jl"), "@test 1 == 1\n")
            git_commit_all!(dir, "base")
            run_git_cmd(dir, "mv", "test/case.jl", "test/renamed.jl"; cwd = dir)
            write(joinpath(dir, "test", "runtests.jl"), "include(\"renamed.jl\")\n")
            git_commit_all!(dir, "rename and fix driver")
            cd(dir) do
                res = AgentRuleLint.check(dir; diff_base = "HEAD^1")
                deleted_hits = filter(
                    d -> d.rule_id == "test-integrity" && d.expect_status == AgentRuleLint.ExpectStatus.DELETED_TEST,
                    res.violations,
                )
                @test isempty(deleted_hits)
            end
        finally
            rm(dir, recursive = true, force = true)
        end
    end

    @testset "fold budget exhaustion is analysis-incomplete" begin
        path = rel("test_integrity_fold_budget.jl")
        res = check_rel(path)
        hits = filter(
            d -> d.rule_id == AgentRuleLint.ANALYSIS_INCOMPLETE_RULE && !d.suppressed,
            res.violations,
        )
        @test !isempty(hits)
        @test all(d -> d.level == AgentRuleLint.Level.FORBID, hits)

        path_const = rel("test_integrity_fold_budget_const.jl")
        res2 = check_rel(path_const)
        hits2 = filter(
            d -> d.rule_id == AgentRuleLint.ANALYSIS_INCOMPLETE_RULE &&
                endswith(string(d.path), "test_integrity_fold_budget_const.jl") &&
                !d.suppressed,
            res2.violations,
        )
        @test !isempty(hits2)
        @test all(d -> d.level == AgentRuleLint.Level.FORBID, hits2)
    end

    @testset "diff: test-integrity deleted findings use expect_status :deleted_test" begin
        dir = abspath(mktempdir())
        try
            init_git_repo!(dir)
            write(joinpath(dir, ".AgentRuleLint.jl.toml"), cfg)
            mkpath(joinpath(dir, "test"))
            write(joinpath(dir, "test", "runtests.jl"), "include(\"gone.jl\")\n")
            write(joinpath(dir, "test", "gone.jl"), "@test 1 == 1\n")
            git_commit_all!(dir, "base")
            rm(joinpath(dir, "test", "gone.jl"))
            git_commit_all!(dir, "delete only")
            cd(dir) do
                res = AgentRuleLint.check(dir; diff_base = "HEAD^1")
                hits = filter(
                    d -> d.rule_id == "test-integrity" && d.expect_status == AgentRuleLint.ExpectStatus.DELETED_TEST,
                    res.violations,
                )
                @test any(d -> d.path == "test/gone.jl", hits)
            end
        finally
            rm(dir, recursive = true, force = true)
        end
    end

    @testset "diff: renamed-away test/runtests.jl is flagged" begin
        dir = abspath(mktempdir())
        try
            init_git_repo!(dir)
            write(joinpath(dir, ".AgentRuleLint.jl.toml"), cfg)
            mkpath(joinpath(dir, "test"))
            write(joinpath(dir, "test", "runtests.jl"), "include(\"case.jl\")\n")
            write(joinpath(dir, "test", "case.jl"), "@test 1 == 1\n")
            git_commit_all!(dir, "base")
            run_git_cmd(dir, "mv", "test/runtests.jl", "test/driver.jl"; cwd = dir)
            write(joinpath(dir, "test", "driver.jl"), "include(\"case.jl\")\n")
            git_commit_all!(dir, "rename driver")
            cd(dir) do
                res = AgentRuleLint.check(dir; diff_base = "HEAD^1")
                hits = filter(
                    d ->
                    d.rule_id == "test-integrity" &&
                        d.expect_status == AgentRuleLint.ExpectStatus.DELETED_TEST &&
                        d.path == "test/runtests.jl",
                    res.violations,
                )
                @test !isempty(hits)
            end
        finally
            rm(dir, recursive = true, force = true)
        end
    end

    @testset "diff: deleted included test file is flagged" begin
        dir = abspath(mktempdir())
        try
            init_git_repo!(dir)
            write(joinpath(dir, ".AgentRuleLint.jl.toml"), cfg)
            mkpath(joinpath(dir, "test"))
            write(joinpath(dir, "test", "runtests.jl"), "include(\"gone.jl\")\n")
            write(joinpath(dir, "test", "gone.jl"), "@test 1 == 1\n")
            git_commit_all!(dir, "base")
            rm(joinpath(dir, "test", "gone.jl"))
            write(joinpath(dir, "test", "runtests.jl"), "include(\"gone.jl\")\n")
            git_commit_all!(dir, "delete included file")
            cd(dir) do
                res = AgentRuleLint.check(dir; diff_base = "HEAD^1")
                hits = filter(
                    d ->
                    d.rule_id == "test-integrity" &&
                        d.expect_status == AgentRuleLint.ExpectStatus.DELETED_TEST &&
                        d.path == "test/gone.jl",
                    res.violations,
                )
                @test !isempty(hits)
            end
        finally
            rm(dir, recursive = true, force = true)
        end
    end

    @testset "diff: approx pairing survives unrelated insert above" begin
        dir = abspath(mktempdir())
        try
            init_git_repo!(dir)
            write(joinpath(dir, ".AgentRuleLint.jl.toml"), cfg)
            mkpath(joinpath(dir, "test"))
            write(
                joinpath(dir, "test", "pair.jl"),
                """
                @testset "block" begin
                    isapprox(1.0, 2.0; atol=1.0e-12)
                end
                """,
            )
            git_commit_all!(dir, "base")
            write(
                joinpath(dir, "test", "pair.jl"),
                """
                @testset "block" begin
                    isapprox(9.0, 9.0; atol=1.0e-15)
                    isapprox(1.0, 2.0; atol=1.0e-3)
                end
                """,
            )
            git_commit_all!(dir, "insert and loosen")
            cd(dir) do
                res = AgentRuleLint.check(dir; diff_base = "HEAD^1")
                hits = filter(
                    d -> d.rule_id == "test-integrity" && occursin("tolerance loosened", d.message),
                    res.violations,
                )
                @test length(hits) == 1
            end
        finally
            rm(dir, recursive = true, force = true)
        end
    end

    @testset "diff: atol appears where base had none" begin
        dir = abspath(mktempdir())
        try
            init_git_repo!(dir)
            write(joinpath(dir, ".AgentRuleLint.jl.toml"), cfg)
            mkpath(joinpath(dir, "test"))
            write(
                joinpath(dir, "test", "pair.jl"),
                """
                @testset "block" begin
                    isapprox(1.0, 2.0)
                end
                """,
            )
            git_commit_all!(dir, "base")
            write(
                joinpath(dir, "test", "pair.jl"),
                """
                @testset "block" begin
                    isapprox(1.0, 2.0; atol=1.0e-3)
                end
                """,
            )
            git_commit_all!(dir, "add atol")
            cd(dir) do
                res = AgentRuleLint.check(dir; diff_base = "HEAD^1")
                hits = filter(
                    d -> d.rule_id == "test-integrity" && occursin("tolerance loosened", d.message),
                    res.violations,
                )
                @test length(hits) == 1
            end
        finally
            rm(dir, recursive = true, force = true)
        end
    end

end
