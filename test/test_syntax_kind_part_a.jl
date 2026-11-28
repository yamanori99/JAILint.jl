@testset "syntax kind Part A gaps (pinned JuliaSyntax)" begin
    function count_in_tree(tree, pred)
        n = 0
        function walk(n_)
            pred(n_) && (n += 1)
            ch = AgentRuleLint.syntax_children(n_)
            ch === nothing || foreach(walk, ch)
        end
        walk(tree)
        return n
    end

    @testset "mapping audit at pin" begin
        t = AgentRuleLint.parse_source("x = 'y'\n")
        @test count_in_tree(t, n -> AgentRuleLint.syntax_node_summary(n) == "character") == 0
        @test count_in_tree(t, n -> AgentRuleLint.syntax_node_summary(n) == "char") == 1
        @test count_in_tree(t, n -> AgentRuleLint.syntax_kind(n) == AgentRuleLint.KCharExpr) == 1

        t = AgentRuleLint.parse_source("s = \"a\$b\"\n")
        @test count_in_tree(t, n -> AgentRuleLint.syntax_node_summary(n) == "interpolation") == 0
        @test count_in_tree(t, n -> AgentRuleLint.syntax_interpolation_child(n)) == 1

        t = AgentRuleLint.parse_source("begin\n a;\n b\nend\n")
        @test count_in_tree(t, n -> AgentRuleLint.syntax_node_summary(n) == "SemicolonWs") == 0
        @test count_in_tree(t, n -> AgentRuleLint.syntax_kind(n) == AgentRuleLint.KSemicolon) >= 1

        t = AgentRuleLint.parse_source("x = \"hi\"\n")
        @test count_in_tree(t, n -> AgentRuleLint.syntax_node_summary(n) == "string") == 1
        @test count_in_tree(t, n -> AgentRuleLint.syntax_kind(n) == AgentRuleLint.KStringExpr) == 1
        @test count_in_tree(t, n -> AgentRuleLint.syntax_node_summary(n) == "String") >= 1
        @test count_in_tree(t, n -> AgentRuleLint.syntax_kind(n) == AgentRuleLint.KStringLeaf) >= 1
    end

    @testset "char static eval arg (was summary \"character\", never matched)" begin
        function first_char_expr(n, pos)
            AgentRuleLint.syntax_kind(n) == AgentRuleLint.KCharExpr && return (n, pos)
            for (c, p) in AgentRuleLint._child_positions(n, pos)[1]
                hit = first_char_expr(c, p)
                hit !== nothing && return hit
            end
            return nothing
        end
        src = "x = 'a'\n"
        tree = AgentRuleLint.parse_source(src)
        hit = first_char_expr(tree, 1)
        hit === nothing && error("char expr node not found")
        char_node, char_pos = hit
        @test AgentRuleLint._is_static_eval_arg(char_node, src, char_pos)
    end

    @testset "catch block skips semicolon tokens in stmt list" begin
        src = "try\n x()\ncatch e; x=1; return\nend\n"
        tree = AgentRuleLint.parse_source(src)
        sites = AgentRuleLint.collect_try_catch_sites(tree, src)
        isempty(sites) && error("no try/catch site")
        stmts = AgentRuleLint._block_statements(sites[1].catch_body, sites[1].catch_body_pos)
        @test all(c -> AgentRuleLint.syntax_kind(c) != AgentRuleLint.KSemicolon, first.(stmts))
        @test length(stmts) == 3
    end

    @testset "corpus silent-catch (semicolon catch header)" begin
        rel = joinpath("test", "corpus", "kind_part_a_catch_semicolon_header.jl")
        root = normpath(joinpath(@__DIR__, ".."))
        res = AgentRuleLint.check(root; paths = [rel])
        hits = filter(d -> d.rule_id == "silent-catch", res.violations)
        @test !isempty(hits)
        @test any(d -> d.suppressed && d.expect_status == AgentRuleLint.ExpectStatus.FULFILLED, hits)
    end
end
