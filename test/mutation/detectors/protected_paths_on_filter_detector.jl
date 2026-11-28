# Exit contract: 0 = detector alive (modify correctly ignored), 2 = disabled.

using AgentRuleLint

const run_git_cmd = AgentRuleLint.run_git_cmd

function main()
    return AgentRuleLint.git_run_scope() do
        return _protected_paths_on_filter_detector_body()
    end
end

function _protected_paths_on_filter_detector_body()
    dir = mktempdir()
    return try
        run_git_cmd(dir, "init", "-q", "-b", "main"; cwd = dir)
        run_git_cmd(dir, "config", "user.email", "mut@test"; cwd = dir)
        run_git_cmd(dir, "config", "user.name", "mut"; cwd = dir)
        ver = string(pkgversion(AgentRuleLint))
        mkpath(joinpath(dir, "guard"))
        write(joinpath(dir, "guard", "x.jl"), "1\n")
        write(
            joinpath(dir, ".AgentRuleLint.jl.toml"),
            """
            agentrulelint_version = \"=$(ver)\"

            [rules.protected-paths]
            level = \"forbid\"
            paths = [
              { glob = "guard/**", on = ["deleted", "renamed"], reason = "on-filter probe." },
            ]
            """,
        )
        run_git_cmd(dir, "add", "-A"; cwd = dir)
        run_git_cmd(dir, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "base"; cwd = dir)
        write(joinpath(dir, "guard", "x.jl"), "2\n")
        run_git_cmd(dir, "add", "-A"; cwd = dir)
        run_git_cmd(dir, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "mod"; cwd = dir)
        res = AgentRuleLint.check(dir; diff_base = "HEAD^1")
        hits = filter(
            d -> d.rule_id == "protected-paths" && d.path == "guard/x.jl",
            res.violations,
        )
        alive = res.exit_code == 0 && isempty(hits)
        exit(alive ? 0 : 2)
    finally
        rm(dir, recursive = true, force = true)
    end
end

exit(main())
