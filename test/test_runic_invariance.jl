using AgentRuleLint
using Test

# ROOT comes from ParallelTestRunner init_code in test/runtests.jl.

const RUNIC_ENV = joinpath(@__DIR__, "runic_env")

function runic_format_str(code::String)
    path, io = mktemp()
    try
        write(io, code)
        close(io)
        cmd = `julia --project=$RUNIC_ENV --startup-file=no -e 'using Runic; print(Runic.format_string(read(ARGS[1], String)))' $path`
        return String(read(cmd))
    finally
        rm(path, force = true)
    end
end

function diagnostic_signatures(result::CheckResult)
    return Set(
        (
            d.rule_id,
            d.anchor_line,
            AgentRuleLint.wire_name(d.expect_status),
            d.suppressed,
        ) for d in result.violations
    )
end

@testset "Runic invariance (corpus)" begin
    root = ROOT
    corpus_dir = joinpath(@__DIR__, "corpus")
    files = filter(f -> endswith(f, ".jl"), readdir(corpus_dir))
    @test !isempty(files)
    for f in files
        # syntax_error lives outside corpus (parse fail-closed fixture).
        src = read(joinpath(corpus_dir, f), String)
        formatted = runic_format_str(src)
        tmp = mktempdir()
        write(joinpath(tmp, f), src)
        write(joinpath(tmp, ".AgentRuleLint.jl.toml"), read(joinpath(root, ".AgentRuleLint.jl.toml"), String))
        before = AgentRuleLint.run_check(tmp; paths = [f]).violations
        write(joinpath(tmp, f), formatted)
        after = AgentRuleLint.run_check(tmp; paths = [f]).violations
        sig(v) =
            diagnostic_signatures(AgentRuleLint.CheckResult(v, true, 0, AgentRuleLint.ConfigSource(), AgentRuleLint.OutputFormat.HUMAN, 20, 0, 0))
        @test sig(before) == sig(after)
    end
end
