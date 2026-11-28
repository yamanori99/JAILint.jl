@testset "analysis-incomplete rule" begin
    @testset "fold budget collectors report budget_exceeded" begin
        src = "a = \"x\" * \"y\"\nb = \"p\" * \"q\"\nc = \"r\" * \"s\"\n"
        tree = AgentRuleLint.parse_source(src)
        partial = AgentRuleLint.collect_folded_string_exprs(tree, src; max_steps = 15)
        @test !isempty(partial.folds)
        @test partial.budget_exceeded
        cmd_src = "Cmd([$(join(fill("\"a\"", 200), ", "))])\n"
        cmd_tree = AgentRuleLint.parse_source(cmd_src)
        cmd_partial = AgentRuleLint.collect_cmd_string_literals(cmd_tree, cmd_src; max_steps = 15)
        @test cmd_partial.budget_exceeded
        @test AgentRuleLint._fold_budget_exceeded(AgentRuleLint.FoldBudgetExceeded(15))
    end

    @testset "not expect-suppressible by rule id" begin
        source = "x = 1\n"
        d = AgentRuleLint.Violation(
            AgentRuleLint.ANALYSIS_INCOMPLETE_RULE,
            AgentRuleLint.Origin.AGENTRULELINT,
            AgentRuleLint.Level.FORBID,
            "f.jl",
            AgentRuleLint.Span(1, 1, 1, 1),
            1,
            "",
            AgentRuleLint.ExpectStatus.NONE,
            false,
            AgentRuleLint.analysis_incomplete_message("f.jl", "project/no-pad"),
            "i",
            "d",
        )
        diags = [d]
        expects = [
            AgentRuleLint.ExpectLine(
                1,
                AgentRuleLint.ANALYSIS_INCOMPLETE_RULE,
                "excuse long enough",
                "raw",
            ),
        ]
        AgentRuleLint.apply_expect_suppression!(diags, expects, source)
        @test !diags[1].suppressed
        @test AgentRuleLint.is_analysis_incomplete(diags[1])
    end

    @testset "project-rule fold budget emits analysis-incomplete" begin
        root = mktempdir()
        try
            v = string(pkgversion(AgentRuleLint))
            write(
                joinpath(root, ".AgentRuleLint.jl.toml"),
                """
                agentrulelint_version = \"=$(v)\"
                [rules.expect-audit]
                level = \"forbid\"
                on_allow_rule = \"warn\"
                [[project_rules]]
                id = \"no-pad\"
                level = \"deny\"
                paths = [\"**/*.jl\"]
                forbid_literals = [\"SECRET_PAD\"]
                intent = \"t\"
                do_not = \"d\"
                """,
            )
            pad = join(fill("\"a\"", 5000), " * ")
            write(joinpath(root, "padded.jl"), "x = $pad\ny = \"SECRET_PAD\"\n")
            res = AgentRuleLint.check(root; paths = ["padded.jl"])
            incomplete = filter(AgentRuleLint.is_analysis_incomplete, res.violations)
            @test length(incomplete) == 1
            @test incomplete[1].level == AgentRuleLint.Level.FORBID && !incomplete[1].suppressed
            @test occursin("(project/no-pad)", incomplete[1].message)
            @test res.exit_code == 1
        finally
            rm(root, recursive = true, force = true)
        end
    end

    @testset "one analysis-incomplete finding per file" begin
        path = joinpath("test", "corpus", "test_integrity_fold_budget.jl")
        res = AgentRuleLint.check(ROOT; paths = [path])
        incomplete = filter(
            d -> AgentRuleLint.is_analysis_incomplete(d) && endswith(string(d.path), "test_integrity_fold_budget.jl"),
            res.violations,
        )
        @test length(incomplete) == 1
        # Prefer test-integrity's `@test` span over the project fold-walk point.
        @test occursin("(test-integrity)", incomplete[1].message)
        @test incomplete[1].span.start_col == 1
        @test incomplete[1].span.end_col > incomplete[1].span.start_col
    end

    @testset "dedupe prefers wider syntactic span over fold-walk point" begin
        path = "budget.jl"
        point = AgentRuleLint.Violation(
            AgentRuleLint.ANALYSIS_INCOMPLETE_RULE,
            AgentRuleLint.Origin.AGENTRULELINT,
            AgentRuleLint.Level.FORBID,
            path,
            AgentRuleLint.Span(2, 31988, 2, 31988),
            2,
            "",
            AgentRuleLint.ExpectStatus.NONE,
            false,
            AgentRuleLint.analysis_incomplete_message(path, "project/no-pad"),
            "i",
            "d",
        )
        wide = AgentRuleLint.Violation(
            AgentRuleLint.ANALYSIS_INCOMPLETE_RULE,
            AgentRuleLint.Origin.AGENTRULELINT,
            AgentRuleLint.Level.FORBID,
            path,
            AgentRuleLint.Span(2, 1, 2, 128042),
            2,
            "",
            AgentRuleLint.ExpectStatus.NONE,
            false,
            AgentRuleLint.analysis_incomplete_message(path, "test-integrity"),
            "i",
            "d",
        )
        # Point first (as project rules append before test-integrity).
        kept = AgentRuleLint.dedupe_analysis_incomplete!([point, wide])
        @test length(kept) == 1
        @test occursin("(test-integrity)", kept[1].message)
        @test kept[1].span == wide.span
        # Wide first still keeps the wide span.
        kept2 = AgentRuleLint.dedupe_analysis_incomplete!([wide, point])
        @test length(kept2) == 1
        @test kept2[1].span == wide.span
        # Equal extent: earlier start wins.
        a = AgentRuleLint.Violation(
            AgentRuleLint.ANALYSIS_INCOMPLETE_RULE,
            AgentRuleLint.Origin.AGENTRULELINT,
            AgentRuleLint.Level.FORBID,
            path,
            AgentRuleLint.Span(3, 1, 3, 9),
            3,
            "",
            AgentRuleLint.ExpectStatus.NONE,
            false,
            AgentRuleLint.analysis_incomplete_message(path, "test-integrity"),
            "i",
            "d",
        )
        b = AgentRuleLint.Violation(
            AgentRuleLint.ANALYSIS_INCOMPLETE_RULE,
            AgentRuleLint.Origin.AGENTRULELINT,
            AgentRuleLint.Level.FORBID,
            path,
            AgentRuleLint.Span(3, 5, 3, 13),
            3,
            "",
            AgentRuleLint.ExpectStatus.NONE,
            false,
            AgentRuleLint.analysis_incomplete_message(path, "project/no-pad"),
            "i",
            "d",
        )
        kept3 = AgentRuleLint.dedupe_analysis_incomplete!([b, a])
        @test length(kept3) == 1
        @test kept3[1].span == a.span
    end

    @testset "level cannot be weakened" begin
        root = mktempdir()
        try
            v = string(pkgversion(AgentRuleLint))
            write(
                joinpath(root, ".AgentRuleLint.jl.toml"),
                """
                agentrulelint_version = \"=$(v)\"
                [rules.analysis-incomplete]
                level = \"deny\"
                """,
            )
            @test_throws AgentRuleLint.ConfigError AgentRuleLint.resolve_policy(root)
        finally
            rm(root, recursive = true, force = true)
        end
    end

    @testset "explain exists" begin
        text = AgentRuleLint.explain_rule(AgentRuleLint.ANALYSIS_INCOMPLETE_RULE; root = ROOT)
        @test occursin("analysis-incomplete", text)
        @test occursin("constant-fold", text)
    end
end
