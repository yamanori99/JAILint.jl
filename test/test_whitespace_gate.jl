@testset "whitespace gate script" begin
    _gate_script = joinpath(ROOT, "scripts", "whitespace-gate.sh")
    _EMPTY_GITHUB_BEFORE = "0000000000000000000000000000000000000000"

    function _self_diff_range(repo::AbstractString)
        head = strip(git_read(repo, "rev-parse", "HEAD"))
        return "$(head)..$(head)"
    end

    function _run_gate(repo::AbstractString; diff_range = nothing, extra_env = Pair{String, String}[])
        repo = abspath(String(repo))
        cmd = `bash $(_gate_script)`
        env_pairs = Pair{String, Union{String, Nothing}}[
            "WHITESPACE_GATE_REPO" => repo,
            "WHITESPACE_GATE_DIFF_RANGE" => diff_range === nothing ? nothing : String(diff_range),
            "GITHUB_EVENT_NAME" => nothing,
            "GITHUB_BASE_REF" => nothing,
            "GITHUB_BEFORE" => nothing,
            "GITHUB_SHA" => nothing,
        ]
        for (k, v) in extra_env
            env_pairs = [p for p in env_pairs if first(p) != k]
            push!(env_pairs, k => v)
        end
        return withenv(env_pairs...) do
            run(ignorestatus(setenv(cmd; dir = repo)))
        end
    end

    function _run_gate_io(
            repo::AbstractString;
            diff_range = nothing,
            extra_env = Pair{String, String}[],
        )
        repo = abspath(String(repo))
        cmd = `bash $(_gate_script)`
        env_pairs = Pair{String, Union{String, Nothing}}[
            "WHITESPACE_GATE_REPO" => repo,
            "WHITESPACE_GATE_DIFF_RANGE" => diff_range === nothing ? nothing : String(diff_range),
            "GITHUB_EVENT_NAME" => nothing,
            "GITHUB_BASE_REF" => nothing,
            "GITHUB_BEFORE" => nothing,
            "GITHUB_SHA" => nothing,
        ]
        for (k, v) in extra_env
            env_pairs = [p for p in env_pairs if first(p) != k]
            push!(env_pairs, k => v)
        end
        stdout = IOBuffer()
        stderr = IOBuffer()
        proc = withenv(env_pairs...) do
            return run(ignorestatus(pipeline(setenv(cmd; dir = repo); stdout, stderr)), wait = true)
        end
        return (
            proc,
            String(take!(stdout)),
            String(take!(stderr)),
        )
    end

    function _gate_repo()
        dir = mktempdir()
        init_git_repo!(dir)
        return dir
    end

    function _write_tracked!(repo::AbstractString, rel::AbstractString, bytes::AbstractVector{UInt8})
        path = joinpath(repo, rel)
        mkpath(dirname(path))
        open(path, "w") do io
            write(io, bytes)
        end
        git_commit_all!(repo, "add $(rel)")
        return nothing
    end

    @testset "trailing newline fixtures" begin
        @testset "missing final newline fails" begin
            repo = _gate_repo()
            try
                _write_tracked!(repo, "a.txt", b"hi")
                proc = _run_gate(repo; diff_range = _self_diff_range(repo))
                @test proc.exitcode == 1
            finally
                rm(repo; force = true, recursive = true)
            end
        end

        @testset "two trailing newlines fail" begin
            repo = _gate_repo()
            try
                _write_tracked!(repo, "b.txt", b"ok\n\n")
                proc = _run_gate(repo; diff_range = _self_diff_range(repo))
                @test proc.exitcode == 1
            finally
                rm(repo; force = true, recursive = true)
            end
        end

        @testset "exactly one trailing newline passes" begin
            repo = _gate_repo()
            try
                _write_tracked!(repo, "c.txt", b"ok\n")
                proc = _run_gate(repo; diff_range = _self_diff_range(repo))
                @test proc.exitcode == 0
            finally
                rm(repo; force = true, recursive = true)
            end
        end

        @testset "binary without newline passes" begin
            repo = _gate_repo()
            try
                _write_tracked!(repo, "bin.dat", UInt8[0x00, 0x01, 0x02])
                proc = _run_gate(repo; diff_range = _self_diff_range(repo))
                @test proc.exitcode == 0
            finally
                rm(repo; force = true, recursive = true)
            end
        end
    end

    @testset "git diff --check trailing whitespace" begin
        repo = _gate_repo()
        try
            _write_tracked!(repo, "clean.txt", b"x\n")
            path = joinpath(repo, "clean.txt")
            open(path, "w") do io
                write(io, "line \n")
            end
            run_git_cmd(repo, "add", "clean.txt"; cwd = repo)
            run_git_cmd(
                repo,
                "-c",
                "commit.gpgsign=false",
                "commit",
                "-q",
                "-m",
                "trailing space";
                cwd = repo,
            )
            base = strip(git_read(repo, "rev-parse", "HEAD~1"))
            proc = _run_gate(repo; diff_range = "$(base)..HEAD")
            @test proc.exitcode != 0
        finally
            rm(repo; force = true, recursive = true)
        end
    end

    @testset "diff range selection" begin
        @testset "missing origin/main without override fails closed" begin
            repo = _gate_repo()
            try
                _write_tracked!(repo, "ok.txt", b"x\n")
                proc, _out, err = _run_gate_io(repo)
                @test proc.exitcode != 0
                @test occursin("WHITESPACE_GATE_DIFF_RANGE", err)
            finally
                rm(repo; force = true, recursive = true)
            end
        end

        @testset "WHITESPACE_GATE_DIFF_RANGE override is used" begin
            repo = _gate_repo()
            try
                _write_tracked!(repo, "ok.txt", b"x\n")
                range = _self_diff_range(repo)
                proc, out, _err = _run_gate_io(repo; diff_range = range)
                @test proc.exitcode == 0
                @test occursin("git diff --check range: $(range)", out)
            finally
                rm(repo; force = true, recursive = true)
            end
        end

        @testset "push with empty GITHUB_BEFORE documents new-branch skip" begin
            repo = _gate_repo()
            try
                _write_tracked!(repo, "ok.txt", b"x\n")
                head = strip(git_read(repo, "rev-parse", "HEAD"))
                proc, out, _err = _run_gate_io(
                    repo;
                    extra_env = [
                        "GITHUB_EVENT_NAME" => "push",
                        "GITHUB_BEFORE" => _EMPTY_GITHUB_BEFORE,
                        "GITHUB_SHA" => head,
                    ],
                )
                @test proc.exitcode == 0
                @test occursin("empty GITHUB_BEFORE (new branch)", out)
                @test occursin("git diff --check range: <none>", out)
            finally
                rm(repo; force = true, recursive = true)
            end
        end
    end

    @testset "repository tree passes when clean" begin
        head = strip(git_read(ROOT, "rev-parse", "HEAD"))
        # Hermetic: diff --check uses HEAD..HEAD only; newline audit still covers the real tree.
        proc = _run_gate(ROOT; diff_range = "$(head)..$(head)")
        @test proc.exitcode == 0
    end
end
