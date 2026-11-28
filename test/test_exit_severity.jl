@testset "exit_severity" begin
    function _pin_config(extra::AbstractString = "")
        v = string(pkgversion(AgentRuleLint))
        return """
        agentrulelint_version = \"=$(v)\"
        default_format = \"human\"
        $extra
        [rules.expect-audit]
        level = \"forbid\"
        on_allow_rule = \"warn\"
        """
    end

    @testset "default warn matches any-hit exit (repo corpus)" begin
        res = AgentRuleLint.check(ROOT; paths = [joinpath("test", "corpus")])
        res_default = AgentRuleLint.check(
            ROOT;
            paths = [joinpath("test", "corpus")],
            exit_severity = :warn,
        )
        @test res.exit_code == res_default.exit_code
        @test res.violation_count == res_default.violation_count
    end

    @testset "forbid threshold skips warn-only hits" begin
        relp = joinpath("test", "corpus", "unsafe_allow_module.jl")
        res = AgentRuleLint.check(ROOT; paths = [relp], exit_severity = :forbid)
        hits = filter(
            d -> d.rule_id == "unsafe-boundary" && !d.suppressed,
            res.violations,
        )
        @test !isempty(hits)
        @test all(d -> d.level == AgentRuleLint.Level.WARN, hits)
        @test res.exit_code == 0
    end

    @testset "forbid-level findings fail every threshold" begin
        relp = joinpath("test", "corpus", "expect_empty_reason.jl")
        for th in (:warn, :deny, :forbid)
            res = AgentRuleLint.check(ROOT; paths = [relp], exit_severity = th)
            forbid_hits = filter(d -> d.level == AgentRuleLint.Level.FORBID && !d.suppressed, res.violations)
            @test !isempty(forbid_hits)
            @test res.exit_code == 1
        end
    end

    @testset "deny-only hits respect forbid threshold" begin
        relp = joinpath("test", "corpus", "silent_catch_empty.jl")
        res = AgentRuleLint.check(ROOT; paths = [relp], exit_severity = :forbid)
        deny_hits = filter(d -> d.level == AgentRuleLint.Level.DENY && !d.suppressed, res.violations)
        forbid_hits = filter(d -> d.level == AgentRuleLint.Level.FORBID && !d.suppressed, res.violations)
        @test !isempty(deny_hits)
        @test isempty(forbid_hits)
        @test res.exit_code == 0
    end

    @testset "config exit_severity" begin
        root = mktempdir()
        try
            write(joinpath(root, ".AgentRuleLint.jl.toml"), _pin_config("exit_severity = \"forbid\"\n"))
            pol = AgentRuleLint.resolve_policy(root)
            @test pol.exit_severity == AgentRuleLint.Level.FORBID
            relp = joinpath("test", "corpus", "unsafe_allow_module.jl")
            res = AgentRuleLint.check(
                ROOT;
                paths = [relp],
                config_path = joinpath(root, ".AgentRuleLint.jl.toml"),
            )
            @test res.exit_code == 0
            write(
                joinpath(root, ".AgentRuleLint.jl.toml"),
                _pin_config("exit_severity = \"nope\"\n"),
            )
            @test_throws AgentRuleLint.ConfigError AgentRuleLint.resolve_policy(root)
            write(
                joinpath(root, ".AgentRuleLint.jl.toml"),
                _pin_config("exit_severity = \"allow\"\n"),
            )
            @test_throws AgentRuleLint.ConfigError AgentRuleLint.resolve_policy(root)
        finally
            rm(root, recursive = true, force = true)
        end
    end

    @testset "CLI unknown exit_severity" begin
        @test AgentRuleLint.cli_main(["check", "--exit-severity", "hint", "test/corpus"]) == 2
        @test AgentRuleLint.cli_main(["check", "--exit-severity=error", "test/corpus"]) == 2
        @test AgentRuleLint.cli_main(["check", "--exit-severity", "allow", "test/corpus"]) == 2
        @test AgentRuleLint.cli_main(["check", "--exit-severity"]) == 2
    end

    @testset "CLI missing value message" begin
        mktemp() do path, io
            redirect_stderr(io) do
                @test AgentRuleLint.cli_main(["check", "--exit-severity"]) == 2
            end
            flush(io)
            err = read(path, String)
            @test occursin("--exit-severity requires a value (forbid|deny|warn)", err)
        end
    end

    @testset "CLI override without config exit_severity labels default baseline" begin
        root = mktempdir()
        old = pwd()
        try
            cfg = joinpath(root, ".AgentRuleLint.jl.toml")
            write(cfg, _pin_config())
            cd(ROOT)
            mktemp() do path, io
                redirect_stdout(io) do
                    code = AgentRuleLint.cli_main(
                        [
                            "check",
                            "--config",
                            cfg,
                            "--format",
                            "human",
                            "--exit-severity",
                            "deny",
                            "test/corpus/unsafe_allow_module.jl",
                        ],
                    )
                    @test code == 0
                end
                flush(io)
                out = replace(read(path, String), r"\s+" => " ")
                @test occursin("default warn", out)
                @test !occursin("config warn", out)
            end
        finally
            cd(old)
            rm(root, recursive = true, force = true)
        end
    end

    @testset "CLI raise threshold prints override and below-threshold count" begin
        root = mktempdir()
        old = pwd()
        try
            cfg = joinpath(root, ".AgentRuleLint.jl.toml")
            write(
                cfg,
                string(
                    _pin_config("exit_severity = \"warn\"\n"),
                    "[rules.unsafe-boundary]\n",
                    "level = \"warn\"\n",
                    "allow_modules = []\n",
                    "allow_globs = []\n",
                ),
            )
            cd(ROOT)
            mktemp() do path, io
                redirect_stdout(io) do
                    code = AgentRuleLint.cli_main(
                        [
                            "check",
                            "--config",
                            cfg,
                            "--format",
                            "human",
                            "--exit-severity",
                            "forbid",
                            "test/corpus/unsafe_allow_module.jl",
                        ],
                    )
                    @test code == 0
                end
                flush(io)
                out = replace(read(path, String), r"\s+" => " ")
                @test occursin("PASSED", out)
                @test occursin("threshold forbid from --exit-severity", out)
                @test occursin("config warn", out)
                @test occursin("below threshold", out)
                @test occursin("warn finding", out)
            end
        finally
            cd(old)
            rm(root, recursive = true, force = true)
        end
    end

    @testset "config threshold has no CLI override note" begin
        root = mktempdir()
        try
            cfg = joinpath(root, ".AgentRuleLint.jl.toml")
            write(
                cfg,
                string(
                    _pin_config("exit_severity = \"forbid\"\n"),
                    "[rules.unsafe-boundary]\n",
                    "level = \"warn\"\n",
                    "allow_modules = []\n",
                    "allow_globs = []\n",
                ),
            )
            res = AgentRuleLint.check(
                ROOT;
                paths = [joinpath("test", "corpus", "unsafe_allow_module.jl")],
                config_path = cfg,
            )
            @test res.exit_code == 0
            @test res.exit_severity == AgentRuleLint.Level.FORBID
            @test res.exit_severity_source == AgentRuleLint.SeveritySource.CONFIG
            @test res.below_threshold_count > 0
            human = AgentRuleLint.format_human(
                res;
                root = ROOT,
                io = IOContext(IOBuffer(), :color => false),
            )
            @test occursin("PASSED", human)
            @test occursin("below threshold", human)
            @test !occursin("from --exit-severity", human)
        finally
            rm(root, recursive = true, force = true)
        end
    end

    @testset "CLI overrides config" begin
        root = mktempdir()
        try
            cfg = joinpath(root, ".AgentRuleLint.jl.toml")
            write(
                cfg,
                string(
                    _pin_config("exit_severity = \"forbid\"\n"),
                    "[rules.unsafe-boundary]\n",
                    "level = \"warn\"\n",
                    "allow_modules = []\n",
                    "allow_globs = []\n",
                ),
            )
            old = pwd()
            try
                cd(ROOT)
                @test AgentRuleLint.cli_main(
                    [
                        "check",
                        "--config",
                        cfg,
                        "--exit-severity",
                        "warn",
                        "test/corpus/unsafe_allow_module.jl",
                    ],
                ) == 1
            finally
                cd(old)
            end
        finally
            rm(root, recursive = true, force = true)
        end
    end
end
