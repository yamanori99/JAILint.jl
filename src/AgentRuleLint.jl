module AgentRuleLint

using Git
using JuliaSyntax
using PrecompileTools
using StyledStrings
using TOML
using SHA: sha1
export CheckResult, RuleSpec, Span, Violation, check
export ConfigError, GitError, InternalError, ParseError

const AGENTRULELINT_VERSION = pkgversion(@__MODULE__)

include("enums.jl")
include("types.jl")
include("fingerprints.jl")
include("path_glob.jl")
include("syntax/SyntaxAdapter.jl")
include("git.jl")
include("config.jl")
include("diff.jl")
include("user_paths.jl")
include("ratchet.jl")
include("expect.jl")
include("rules/common.jl")
include("rules/project_rules.jl")
include("rules/builtin_rules.jl")
include("rules/registry.jl")
include("exit_severity.jl")
include("runner.jl")
include("format/records.jl")
include("format/json.jl")
include("format/width.jl")
include("format/common.jl")
include("format/human.jl")
include("format/agent.jl")
include("format/report.jl")

function _normalize_check_inputs!(kwargs)
    nt = NamedTuple(kwargs)
    paths = get(kwargs, :paths, String[])
    if !isempty(paths)
        given = String[string(p) for p in paths]
        nt = merge(nt, (; user_paths_given = given, paths = normalize_path.(given)))
    end
    allow_raw = get(kwargs, :allow_paths, nothing)
    allow_raw === nothing && return nt
    diff_base = get(kwargs, :diff_base, nothing)
    if allow_raw isa Vector{Regex}
        validate_allow_paths_kw(allow_raw, diff_base)
        return nt
    elseif allow_raw isa AbstractVector
        strings = String[string(x) for x in allow_raw]
        regexes = compile_allow_path_globs(strings)
        validate_allow_paths_kw(regexes, diff_base)
        return merge(nt, (; allow_paths = regexes))
    end
    throw(ConfigError("allow_paths must be a vector of glob strings or compiled Regex values"))
end

"""
    check(root; kwargs...) -> CheckResult

Run the AgentRuleLint pipeline on `root`. Safe to call concurrently from multiple
threads or tasks: each invocation uses its own policy resolution and built-in
rule registry (no shared mutable linter state).
"""
function check(root::AbstractString; kwargs...)
    try
        return run_check(root; kwargs...)
    catch err
        if err isa InterruptException
            rethrow()
        end
        is_fail_closed(err) && rethrow()
        bt = stacktrace(catch_backtrace())
        throw(InternalError(format_error(err), bt))
    end
end

function _parse_cli_format(raw::AbstractString)
    try
        return parse_enum(OutputFormat.T, raw)
    catch err
        err isa ConfigError || rethrow()
        valid = join(wire_name.(instances(OutputFormat.T)), "|")
        throw(ArgumentError("unknown --format value '$raw' (expected $valid)"))
    end
end

function _parse_cli_args(cmd::String, rest::Vector{String})
    opts = Dict{Symbol, Any}(
        :format => nothing,
        :config_path => nothing,
        :config_from => nothing,
        :diff_base => nothing,
        :diff_mode => false,
        :output => nothing,
        :paths => String[],
        :allow_paths => nothing,
        :write_ratchet => false,
        :exit_severity => nothing,
    )
    i = 1
    positional = String[]
    while i <= length(rest)
        a = rest[i]
        if a == "--format" && i + 1 <= length(rest)
            opts[:format] = _parse_cli_format(rest[i + 1])
            i += 2
            continue
        elseif startswith(a, "--format=")
            opts[:format] = _parse_cli_format(a[(length("--format=") + 1):end])
        elseif a == "--config" && i + 1 <= length(rest)
            opts[:config_path] = rest[i + 1]
            i += 2
            continue
        elseif a == "--config-from" && i + 1 <= length(rest)
            opts[:config_from] = rest[i + 1]
            i += 2
            continue
        elseif a == "--diff"
            if i + 1 <= length(rest) && !startswith(rest[i + 1], "-")
                opts[:diff_base] = rest[i + 1]
                i += 2
            else
                opts[:diff_mode] = true
                i += 1
            end
            continue
        elseif a == "--output" && i + 1 <= length(rest)
            opts[:output] = rest[i + 1]
            i += 2
            continue
        elseif a == "--exit-severity"
            opts[:exit_severity] !== nothing &&
                throw(ArgumentError("duplicate --exit-severity"))
            if i + 1 > length(rest) || startswith(rest[i + 1], "-")
                throw(ArgumentError("--exit-severity requires a value (forbid|deny|warn)"))
            end
            opts[:exit_severity] = rest[i + 1]
            i += 2
            continue
        elseif startswith(a, "--exit-severity=")
            opts[:exit_severity] !== nothing &&
                throw(ArgumentError("duplicate --exit-severity"))
            opts[:exit_severity] = a[(length("--exit-severity=") + 1):end]
        elseif a == "--allow-paths" && i + 1 <= length(rest)
            opts[:allow_paths] !== nothing &&
                throw(ArgumentError("duplicate --allow-paths"))
            opts[:allow_paths] = parse_allow_paths_cli(rest[i + 1])
            i += 2
            continue
        elseif startswith(a, "--allow-paths=")
            opts[:allow_paths] !== nothing &&
                throw(ArgumentError("duplicate --allow-paths"))
            opts[:allow_paths] = parse_allow_paths_cli(a[(length("--allow-paths=") + 1):end])
        elseif a == "--write"
            cmd == "ratchet" || throw(
                ArgumentError("unknown option for $cmd: --write (use agentrulelint ratchet --write)"),
            )
            opts[:write_ratchet] = true
        elseif startswith(a, "-")
            throw(ArgumentError("unknown option: $a"))
        else
            push!(positional, a)
        end
        i += 1
    end
    return positional, opts
end

function _emit_fail_closed(err, io = stderr)
    if err isa InternalError
        println(io, "AgentRuleLint internal error: ", err.msg)
        if !isempty(err.bt)
            Base.show_backtrace(io, err.bt)
            println(io)
        end
        return 3
    elseif is_fail_closed(err)
        println(io, "AgentRuleLint fail-closed: ", format_error(err))
        return 2
    elseif err isa ArgumentError
        println(io, "AgentRuleLint: ", err.msg)
        return 2
    else
        println(io, "AgentRuleLint bug: ", format_error(err))
        return 3
    end
end

"""Exit code for a thrown error after CLI catch (`InternalError` → 3, fail-closed / `ArgumentError` → 2, else → 3)."""
function exit_code_for_error(err)
    return _emit_fail_closed(err, devnull)
end

function _resolve_emit_format(result::CheckResult, opts)
    fmt = opts[:format]
    if fmt === nothing
        return result.default_format
    end
    return fmt
end

function _emit(result::CheckResult, fmt::OutputFormat.T, opts; root::AbstractString = pwd())
    out_path = opts[:output]
    if out_path === nothing
        io = IOContext(stdout, :color => stdout isa Base.TTY)
        text = fmt === OutputFormat.JSON ? format_json(result) :
            fmt === OutputFormat.AGENT ? format_agent(result; root = root, io = io) :
            format_human(result; root = root, io = io)
        return print(text)
    end
    plain_io = IOContext(IOBuffer(), :color => false)
    text = fmt === OutputFormat.JSON ? format_json(result) :
        fmt === OutputFormat.AGENT ? format_agent(result; root = root, io = plain_io) :
        format_human(result; root = root, io = plain_io)
    return write(out_path, text)
end

function _resolve_diff_kw(opts)
    if opts[:diff_base] !== nothing
        return resolve_diff_base_arg(opts[:diff_base])
    elseif opts[:diff_mode]
        return DEFAULT_DIFF_BASE
    end
    return nothing
end

function _cli_check(positional::Vector{String}, opts)
    root = pwd()
    paths = isempty(positional) ? String[] : positional
    opts[:exit_severity] !== nothing && _parse_exit_severity_cli(opts[:exit_severity])
    result = check(
        root;
        paths = paths,
        config_path = opts[:config_path],
        config_from = opts[:config_from],
        diff_base = _resolve_diff_kw(opts),
        allow_paths = opts[:allow_paths],
        exit_severity = opts[:exit_severity],
    )
    fmt = _resolve_emit_format(result, opts)
    _emit(result, fmt, opts; root = root)
    return result.exit_code
end

function _cli_init(::Vector{String}, ::Dict)
    root = pwd()
    reject_legacy_config_file!(root)
    path = joinpath(root, CONFIG_FILENAME)
    isfile(path) &&
        throw(ConfigError("config already exists: $CONFIG_FILENAME"))
    write(path, render_init_config())
    println("Wrote $(abspath(path))")
    return 0
end

function _cli_explain(positional::Vector{String}, ::Dict)
    isempty(positional) && throw(ArgumentError("explain requires <rule-id>"))
    println(explain_rule(positional[1]; root = pwd()))
    return 0
end

function _cli_report(positional::Vector{String}, ::Dict)
    isempty(positional) && throw(ArgumentError("report requires <fingerprint>"))
    fp = positional[1]
    root = pwd()
    result = check(root)
    matches = filter(d -> d.fingerprint == fp, result.violations)
    isempty(matches) && throw(ArgumentError("fingerprint not found: $fp"))
    d = first(matches)
    ap = joinpath(root, d.path)
    src = isfile(ap) ? normalize_source(read(ap, String)) : ""
    print(format_report(fp, d, src))
    return 0
end

function _ratchet_scope_paths(root::AbstractString, diff_base, paths::Vector{String}, policy::PolicyBundle)
    if diff_base !== nothing
        project_regexes = project_rule_path_regexes(policy)
        return Set(
            discover_files(root; paths = String[], diff_base = diff_base, project_regexes = project_regexes),
        )
    elseif !isempty(paths)
        project_regexes = project_rule_path_regexes(policy)
        return Set(discover_files(root; paths = paths, diff_base = nothing, project_regexes = project_regexes))
    end
    return Set{String}()
end

function _cli_ratchet(positional::Vector{String}, opts)
    root = pwd()
    paths = positional
    diff_base = _resolve_diff_kw(opts)
    result, contexts = run_check_pipeline(
        root;
        paths = paths,
        config_path = opts[:config_path],
        config_from = opts[:config_from],
        diff_base = diff_base,
    )
    return git_run_scope() do
        policy = resolve_policy(
            root;
            config_path = opts[:config_path],
            config_from = opts[:config_from],
        )
        scope_paths = _ratchet_scope_paths(root, diff_base, paths, policy)
        merge_scope = diff_base !== nothing || !isempty(paths)
        ratchet_write!(
            root,
            result,
            contexts;
            merge_scope = merge_scope,
            scope_paths = scope_paths,
            policy = policy,
        )
        println("Wrote $(abspath(joinpath(root, ".agentrulelint/ceilings.toml")))")
        return result.exit_code
    end
end

function _print_cli_help(cmd::String)
    if cmd == "check" || cmd == "help" || cmd == "-h" || cmd == "--help" || cmd == ""
        println(
            """
            Usage: agentrulelint check [paths...] [options]
                   agentrulelint init
                   agentrulelint explain <rule-id>
                   agentrulelint ratchet --write [paths...] [options]
                   agentrulelint report <fingerprint>

            Commands:
              check    Lint Julia sources (default). Reads ceilings; does not write them.
              init     Write a starter $CONFIG_FILENAME in the current directory.
              explain  Print rule intent and anchor semantics for <rule-id>.
              ratchet  Update .agentrulelint/ceilings.toml from current violation counts (--write required).
              report   Emit anonymized JSON for a diagnostic fingerprint.

            Options (check and ratchet --write):
              --format human|json|agent   Output format (default: config default_format; invalid values exit 2)
              --config <path>             Alternate config file path
              --config-from <git-ref>     Load $(CONFIG_FILENAME) from a git ref
              --diff [<base-ref>]         Limit to changed files/lines vs base (default: HEAD^1)
              --allow-paths GLOB,...      Trusted allowlist for scope-paths (requires --diff; not from config)
              --output <path>             Write formatted output to <path>
              --exit-severity forbid|deny|warn
                                          Fail at this level or above (default warn; CLI overrides config)

            Config is fail-closed: unknown keys, rule levels, preset names, or default_format values error.
            """,
        )
    elseif cmd == "ratchet"
        println(
            """
            Usage: agentrulelint ratchet --write [paths...] [options]

            Writes .agentrulelint/ceilings.toml from current violation counts. --write is required.
            A plain check run never updates ceilings.

            Options: same as agentrulelint check (see agentrulelint --help).
            """,
        )
    else
        println("Run agentrulelint --help for usage.")
    end
    return nothing
end

function cli_main(args::AbstractVector{<:AbstractString})::Int
    argvec = String[string(a) for a in args]
    # agentrulelint-expect: silent-catch reason="CLI maps caught errors to fail-closed exit codes after Interrupt pass-through"
    try
        cmd = isempty(argvec) ? "check" : argvec[1]
        if cmd == "help" || cmd == "-h" || cmd == "--help"
            _print_cli_help("help")
            return 0
        end
        rest = length(argvec) > 1 ? argvec[2:end] : String[]
        known_cmds = ("check", "init", "explain", "ratchet", "report")
        cmd in known_cmds || throw(ArgumentError("unknown command: $cmd"))
        if "--help" in rest || "-h" in rest
            _print_cli_help(cmd)
            return 0
        end
        positional, opts = _parse_cli_args(cmd, rest)
        return if cmd == "check"
            _cli_check(positional, opts)
        elseif cmd == "init"
            !isempty(positional) && throw(ArgumentError("init takes no arguments"))
            _cli_init(positional, opts)
        elseif cmd == "explain"
            _cli_explain(positional, opts)
        elseif cmd == "ratchet"
            opts[:write_ratchet] ||
                throw(ArgumentError("ratchet requires --write (updates .agentrulelint/ceilings.toml)"))
            _cli_ratchet(positional, opts)
        elseif cmd == "report"
            _cli_report(positional, opts)
        else
            throw(ArgumentError("unknown command: $cmd"))
        end
    catch err
        if err isa InterruptException
            rethrow()
        end
        return _emit_fail_closed(err)
    end
end

function (@main)(args::Vector{String})::Cint
    return Cint(cli_main(args))
end

@setup_workload begin
    try
        _ = self_check_parser("1 + 1\n")
    catch err
        err isa InterruptException && rethrow()
    end
end

end # module AgentRuleLint
