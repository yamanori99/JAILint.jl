@testset "dogfood script" begin
    _dogfood_script = joinpath(ROOT, "scripts", "dogfood.sh")
    _STUB_LONG = "DOGFOOD_STUB_UNIQUE_$(repeat("x", 4096))"

    function _write_stub!(path::AbstractString)
        body = [
            "#!/usr/bin/env bash",
            "set -euo pipefail",
            "fmt=\"\${DOGFOOD_CHECK_FORMAT}\"",
            "out=\"\${DOGFOOD_OUTPUT_DIR}\"",
            "if [[ \"\${fmt}\" == \"human\" ]]; then",
            "  line=\"\${DOGFOOD_STUB_LINE:-ok}\"",
            "  printf '%s\\n' \"\${line}\" > \"\${out}/human.log\"",
            "elif [[ \"\${fmt}\" == \"json\" ]]; then",
            "  printf '' > \"\${out}/dogfood.jsonl\"",
            "  printf '' > \"\${out}/json.stderr\"",
            "else",
            "  printf 'fmt-%s\\n' \"\${fmt}\" > \"\${out}/\${fmt}.log\"",
            "fi",
            "exit \"\${DOGFOOD_STUB_EXIT:-0}\"",
        ]
        write(path, join(body, '\n') * '\n')
        chmod(path, 0o755)
        return path
    end

    function _two_commit_repo()
        dir = mktempdir()
        init_git_repo!(dir)
        write(joinpath(dir, "Project.toml"), "name = \"StubPkg\"\nversion = \"0.0.1\"\n")
        write(joinpath(dir, "src.jl"), "v = 1\n")
        git_commit_all!(dir, "base")
        run_git_cmd(dir, "branch", "base-tip", "HEAD"; cwd = dir)
        write(joinpath(dir, "src.jl"), "v = 2\n")
        git_commit_all!(dir, "head")
        return dir
    end

    _DOGFOOD_BASE_REF = "base-tip"

    function _run_dogfood(
            repo::AbstractString;
            output_dir::Union{Nothing, AbstractString} = nothing,
            stub_exit::Int = 0,
            stub_line::AbstractString = "ok",
            extra_env = Pair{String, String}[],
            fail_setup::Bool = false,
        )
        repo = abspath(String(repo))
        stub = joinpath(repo, "stub-check.sh")
        _write_stub!(stub)
        out = output_dir === nothing ? mktempdir() : abspath(String(output_dir))
        mkpath(out)
        cmd = `bash $(_dogfood_script) $(_DOGFOOD_BASE_REF) $out human,json`
        env_pairs = Pair{String, Union{String, Nothing}}[
            "DOGFOOD_REPO" => repo,
            "DOGFOOD_TEST_SKIP_PKG_SETUP" => "1",
            "DOGFOOD_TEST_CHECK_CMD" => stub,
            "DOGFOOD_STUB_EXIT" => string(stub_exit),
            "DOGFOOD_STUB_LINE" => String(stub_line),
            "DOGFOOD_TEST_FAIL_SETUP" => fail_setup ? "1" : nothing,
            "HOME" => nothing,
            "GIT_CONFIG_GLOBAL" => nothing,
            "GIT_CONFIG_NOSYSTEM" => nothing,
        ]
        for (k, v) in extra_env
            env_pairs = [p for p in env_pairs if first(p) != k]
            push!(env_pairs, k => v)
        end
        stdout = IOBuffer()
        stderr = IOBuffer()
        proc = withenv(env_pairs...) do
            return run(
                ignorestatus(pipeline(setenv(cmd; dir = repo); stdout, stderr)),
                wait = true,
            )
        end
        wt_count = count(
            !isempty,
            split(strip(git_read(repo, "worktree", "list")), '\n'),
        )
        return (proc, String(take!(stdout)), String(take!(stderr)), out, wt_count)
    end

    @testset "worktree removed after exit 0" begin
        repo = _two_commit_repo()
        try
            proc, _out, _err, _dir, wt = _run_dogfood(repo; stub_exit = 0)
            @test proc.exitcode == 0
            @test wt == 1
        finally
            rm(repo; force = true, recursive = true)
        end
    end

    @testset "worktree removed after exit 1" begin
        repo = _two_commit_repo()
        try
            proc, _out, _err, _dir, wt = _run_dogfood(repo; stub_exit = 1)
            @test proc.exitcode == 1
            @test wt == 1
        finally
            rm(repo; force = true, recursive = true)
        end
    end

    @testset "worktree removed after setup failure" begin
        repo = _two_commit_repo()
        try
            proc, _out, err, _dir, wt = _run_dogfood(repo; fail_setup = true)
            @test proc.exitcode != 0
            @test occursin("instantiate/precompile failed", err)
            @test wt == 1
        finally
            rm(repo; force = true, recursive = true)
        end
    end

    @testset "concurrent runs use separate output dirs" begin
        repo = _two_commit_repo()
        try
            out_a = mktempdir()
            out_b = mktempdir()
            t_a = Threads.@spawn _run_dogfood(repo; output_dir = out_a, stub_exit = 0)
            t_b = Threads.@spawn _run_dogfood(repo; output_dir = out_b, stub_exit = 0)
            pa, pb = fetch(t_a), fetch(t_b)
            @test pa[1].exitcode == 0
            @test pb[1].exitcode == 0
            @test pa[4] != pb[4]
            @test isfile(joinpath(pa[4], "meta.json"))
            @test isfile(joinpath(pb[4], "meta.json"))
        finally
            rm(repo; force = true, recursive = true)
        end
    end

    @testset "noclobber at legacy log path does not block run" begin
        repo = _two_commit_repo()
        legacy = "/tmp/agentrulelint-dogfood.log"
        try
            open(legacy, "w") do io
                println(io, "stale")
            end
            stub = joinpath(repo, "stub-check.sh")
            _write_stub!(stub)
            out = mktempdir()
            inner = """
            set -euo pipefail
            set -o noclobber
            export DOGFOOD_REPO='$repo'
            export DOGFOOD_TEST_SKIP_PKG_SETUP=1
            export DOGFOOD_TEST_CHECK_CMD='$stub'
            export DOGFOOD_STUB_EXIT=0
            bash '$(_dogfood_script)' '$(_DOGFOOD_BASE_REF)' '$out' human,json
            """
            proc = run(ignorestatus(`bash -c $inner`), wait = true)
            @test proc.exitcode == 0
            @test isfile(joinpath(out, "human.log"))
            @test read(joinpath(out, "human.log"), String) == "ok\n"
        finally
            rm(legacy; force = true)
            rm(repo; force = true, recursive = true)
        end
    end

    @testset "output not truncated" begin
        repo = _two_commit_repo()
        try
            proc, out, _err, dir, _wt = _run_dogfood(repo; stub_exit = 0, stub_line = _STUB_LONG)
            @test proc.exitcode == 0
            @test occursin(_STUB_LONG, out)
            logged = read(joinpath(dir, "human.log"), String)
            @test occursin(_STUB_LONG, logged)
        finally
            rm(repo; force = true, recursive = true)
        end
    end
end
