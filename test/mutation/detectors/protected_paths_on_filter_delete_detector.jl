# Exit contract: 0 = detector alive (delete + rename-out reported), 2 = disabled.

using AgentRuleLint

const run_git_cmd = AgentRuleLint.run_git_cmd

function main()
    return AgentRuleLint.git_run_scope() do
        return _protected_paths_on_filter_delete_detector_body()
    end
end

function _guard_cfg(ver::AbstractString)
    return """
    agentrulelint_version = \"=$(ver)\"

    [rules.protected-paths]
    level = \"forbid\"
    paths = [
      { glob = "guard/**", on = ["deleted", "renamed"], reason = "on-filter delete probe." },
    ]
    """
end

function _deleted_on_path(res, path::AbstractString)
    return any(
        d ->
        d.rule_id == "protected-paths" && d.path == path &&
            occursin("deleted", d.message),
        res.violations,
    )
end

function _probe_delete(ver::AbstractString)
    dir = mktempdir()
    return try
        run_git_cmd(dir, "init", "-q", "-b", "main"; cwd = dir)
        run_git_cmd(dir, "config", "user.email", "mut@test"; cwd = dir)
        run_git_cmd(dir, "config", "user.name", "mut"; cwd = dir)
        mkpath(joinpath(dir, "guard"))
        write(joinpath(dir, ".AgentRuleLint.jl.toml"), _guard_cfg(ver))
        write(joinpath(dir, "guard", "a.jl"), "1\n")
        run_git_cmd(dir, "add", "-A"; cwd = dir)
        run_git_cmd(dir, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "base"; cwd = dir)
        rm(joinpath(dir, "guard", "a.jl"))
        run_git_cmd(dir, "add", "-A"; cwd = dir)
        run_git_cmd(dir, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "del"; cwd = dir)
        res = AgentRuleLint.check(dir; diff_base = "HEAD^1")
        return _deleted_on_path(res, "guard/a.jl")
    finally
        rm(dir, recursive = true, force = true)
    end
end

function _probe_rename_out(ver::AbstractString)
    dir = mktempdir()
    return try
        run_git_cmd(dir, "init", "-q", "-b", "main"; cwd = dir)
        run_git_cmd(dir, "config", "user.email", "mut@test"; cwd = dir)
        run_git_cmd(dir, "config", "user.name", "mut"; cwd = dir)
        mkpath(joinpath(dir, "guard"))
        write(joinpath(dir, ".AgentRuleLint.jl.toml"), _guard_cfg(ver))
        write(joinpath(dir, "guard", "b.jl"), "1\n")
        run_git_cmd(dir, "add", "-A"; cwd = dir)
        run_git_cmd(dir, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "base"; cwd = dir)
        run_git_cmd(dir, "mv", "guard/b.jl", "b.jl"; cwd = dir)
        run_git_cmd(dir, "add", "-A"; cwd = dir)
        run_git_cmd(dir, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "out"; cwd = dir)
        res = AgentRuleLint.check(dir; diff_base = "HEAD^1")
        return _deleted_on_path(res, "guard/b.jl")
    finally
        rm(dir, recursive = true, force = true)
    end
end

function _protected_paths_on_filter_delete_detector_body()
    ver = string(pkgversion(AgentRuleLint))
    del_ok = _probe_delete(ver)
    out_ok = _probe_rename_out(ver)
    alive = del_ok && out_ok
    return exit(alive ? 0 : 2)
end

exit(main())
