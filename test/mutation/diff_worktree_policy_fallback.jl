include("mutation_lib.jl")
using AgentRuleLint

const _DETECT = _MUTATION_VERIFY_DETECTED_EXIT

run_source_mutation(;
    name = "diff mode loads working-tree policy",
    rel_path = "src/config.jl",
    needle = "    if worktree_config || diff_base === nothing",
    replacement = "    if true",
    verify = root -> begin
        script = """
        using AgentRuleLint
        using Test
        const FORBIDDEN = "MUT_DIFF_POLICY_LIT"
        function cfg(level)
            ver = string(pkgversion(AgentRuleLint))
            return \"\"\"
            agentrulelint_version = \\\"=\$(ver)\\\"

            [[project_rules]]
            id = \\\"mut-policy\\\"
            level = \\\"\$(level)\\\"
            paths = [\\\"**\\\"]
            forbid_literals = [\\\"\$(FORBIDDEN)\\\"]
            intent = \\\"\\\"
            do_not = \\\"\\\"
            \"\"\"
        end
        const run_git_cmd = AgentRuleLint.run_git_cmd
        tmp = mktempdir()
        try
            run_git_cmd(tmp, "init", "-q", "-b", "main"; cwd = tmp)
            run_git_cmd(tmp, "config", "user.email", "mut@test"; cwd = tmp)
            run_git_cmd(tmp, "config", "user.name", "mut"; cwd = tmp)
            write(joinpath(tmp, ".AgentRuleLint.jl.toml"), cfg("deny"))
            write(joinpath(tmp, "hit.jl"), "1\\n")
            run_git_cmd(tmp, "add", "-A"; cwd = tmp)
            run_git_cmd(tmp, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "strict base"; cwd = tmp)
            write(joinpath(tmp, ".AgentRuleLint.jl.toml"), cfg("allow"))
            write(joinpath(tmp, "hit.jl"), "x = \\\"\$(FORBIDDEN)\\\"\\n")
            run_git_cmd(tmp, "add", "-A"; cwd = tmp)
            run_git_cmd(tmp, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "relaxed head"; cwd = tmp)
            res = AgentRuleLint.check(tmp; diff_base = "HEAD^1")
            n = count(
                d ->
                    d.rule_id == "project/mut-policy" &&
                        d.level == AgentRuleLint.Level.DENY && !d.suppressed,
                res.violations,
            )
            n == 0 ? exit($_DETECT) : exit(0)
        finally
            rm(tmp, recursive=true, force=true)
        end
        """
        return mutation_verify_script(root, script; dir = root)
    end,
)
