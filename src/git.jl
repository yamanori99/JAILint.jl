# Bundled git via Git.jl with config isolation (see #93). Minimum git 2.32 (GIT_CONFIG_GLOBAL).

const GIT_MIN_VERSION = VersionNumber("2.32")

const _TLS_GLOBAL_CONFIG = :agentrulelint_git_global_config
const _TLS_RUNTIME = :agentrulelint_git_runtime
const _TLS_WORKER_WDIR = :agentrulelint_git_worker_wdir

# Inherited env that pins another repository or discovery context (see git(1) ENVIRONMENT).
const _GIT_STRIP_REPO_LOCATION_ENV = (
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_COMMON_DIR",
    "GIT_NAMESPACE",
    "GIT_CEILING_DIRECTORIES",
    "GIT_DISCOVERY_ACROSS_FILESYSTEM",
    "GIT_GRAFT_FILE",
    "GIT_SHALLOW_FILE",
    "GIT_QUARANTINE_PATH",
)

const _GIT_STRIP_CONFIG_SCOPE_ENV = (
    "GIT_CONFIG",
    "GIT_CONFIG_COUNT",
    "GIT_CONFIG_PARAMETERS",
)

function _task_tls()
    return task_local_storage()
end

function _git_global_config_path()
    tls = _task_tls()
    if haskey(tls, _TLS_GLOBAL_CONFIG)
        return tls[_TLS_GLOBAL_CONFIG]::String
    end
    Sys.iswindows() &&
        throw(InternalError("git isolation context missing (git_run_scope)"))
    # Test workers may call git helpers without `git_run_scope`; same empty global config.
    return "/dev/null"
end

function _git_isolated_overrides()
    return Dict{String, String}(
        "GIT_CONFIG_NOSYSTEM" => "1",
        "GIT_ATTR_NOSYSTEM" => "1",
        "GIT_CONFIG_GLOBAL" => _git_global_config_path(),
        "GIT_TERMINAL_PROMPT" => "0",
        "GIT_OPTIONAL_LOCKS" => "0",
        "GIT_PAGER" => "cat",
        "LC_ALL" => "C",
    )
end

function _git_strip_inherited!(env::Dict{String, String})
    for k in _GIT_STRIP_REPO_LOCATION_ENV
        delete!(env, k)
    end
    for k in _GIT_STRIP_CONFIG_SCOPE_ENV
        delete!(env, k)
    end
    for k in collect(keys(env))
        startswith(k, "GIT_CONFIG_KEY_") && delete!(env, k)
        startswith(k, "GIT_CONFIG_VALUE_") && delete!(env, k)
    end
    return env
end

function _cmd_env_dict(cmd::Cmd)
    cmd.env === nothing &&
        throw(GitError("Git.jl bundled git command has no environment"))
    env = Dict{String, String}()
    for entry in cmd.env
        s = String(entry)
        idx = findfirst('=', s)
        idx === nothing && continue
        env[s[1:(idx - 1)]] = s[(idx + 1):end]
    end
    return env
end

"""Resolve Git.jl's bundled git command; fail closed if Git.jl cannot provide it."""
function _bundled_git_cmd()
    try
        return Git.git()
    catch err
        err isa InterruptException && rethrow()
        throw(GitError("Git.jl bundled git is unavailable: $(format_error(err))"))
    end
end

"""Git.jl's bundled-git environment (JLL paths, `GIT_EXEC_PATH`, SSL, …); never strip or override."""
function _git_jll_env(base_cmd::Cmd)
    return _cmd_env_dict(base_cmd)
end

function _git_merged_env(base_cmd::Cmd)
    env = _git_jll_env(base_cmd)
    _git_strip_inherited!(env)
    merge!(env, _git_isolated_overrides())
    return env
end

"""
    git_worker_bootstrap!()

Call once per parallel test worker so git helpers work for the worker lifetime (Windows).
"""
function git_worker_bootstrap!()
    tls = _task_tls()
    haskey(tls, _TLS_GLOBAL_CONFIG) && return nothing
    if Sys.iswindows()
        wdir = mktempdir()
        cfg = joinpath(wdir, "gitconfig")
        touch(cfg)
        tls[_TLS_GLOBAL_CONFIG] = cfg
        tls[_TLS_WORKER_WDIR] = wdir
    else
        tls[_TLS_GLOBAL_CONFIG] = "/dev/null"
    end
    return nothing
end

function git_runtime()
    tls = _task_tls()
    haskey(tls, _TLS_RUNTIME) || return (executable = "", version = "")
    return tls[_TLS_RUNTIME]::NamedTuple{(:executable, :version), Tuple{String, String}}
end

function _git_restore_tls!(
        tls,
        saved_config,
        saved_runtime,
        created_windows_cfg::Union{Nothing, String},
    )
    if saved_config === nothing
        delete!(tls, _TLS_GLOBAL_CONFIG)
    else
        tls[_TLS_GLOBAL_CONFIG] = saved_config
    end
    if saved_runtime === nothing
        delete!(tls, _TLS_RUNTIME)
    else
        tls[_TLS_RUNTIME] = saved_runtime
    end
    if created_windows_cfg !== nothing
        wdir = dirname(created_windows_cfg)
        isdir(wdir) && rm(wdir, recursive = true, force = true)
    end
    return nothing
end

"""
    git_run_scope(f) -> f()

Set per-run git isolation context (`GIT_CONFIG_GLOBAL`, probe cache). Reentrant: restores the
prior task-local context. On Windows, nested scopes use temporary empty global configs.
"""
function git_run_scope(f)
    tls = _task_tls()
    saved_config = get(tls, _TLS_GLOBAL_CONFIG, nothing)
    saved_runtime = get(tls, _TLS_RUNTIME, nothing)
    created_windows_cfg = nothing
    try
        if Sys.iswindows()
            wdir = mktempdir()
            cfg = joinpath(wdir, "gitconfig")
            touch(cfg)
            tls[_TLS_GLOBAL_CONFIG] = cfg
            created_windows_cfg = cfg
        else
            tls[_TLS_GLOBAL_CONFIG] = "/dev/null"
        end
        return f()
    finally
        _git_restore_tls!(tls, saved_config, saved_runtime, created_windows_cfg)
    end
end

function _parse_git_version_output(exe::AbstractString, out::AbstractString)
    s = strip(String(out))
    m = match(r"^git version (\d+\.\d+(?:\.\d+)?)", s)
    if m === nothing
        throw(GitError("git at $exe produced unparseable --version output: $(repr(s))"))
    end
    ver_s = m.captures[1]
    ver_s === nothing &&
        throw(GitError("git at $exe produced unparseable --version output: $(repr(s))"))
    return VersionNumber(ver_s)
end

"""Probe Git.jl bundled git via the isolated entry point; cache for this run."""
function ensure_git_runtime!(root::AbstractString)
    tls = _task_tls()
    if haskey(tls, _TLS_RUNTIME)
        rt = tls[_TLS_RUNTIME]
        !isempty(rt.version) && return rt
    end
    probe_root = (r = abspath(String(root)); isdir(r) ? r : pwd())
    base = _bundled_git_cmd()
    exe = String(base.exec[1])
    tls[_TLS_RUNTIME] = (executable = exe, version = "")
    raw = strip(String(read_git_cmd(probe_root, "--version"; error_prefix = "git --version failed")))
    ver = _parse_git_version_output(exe, raw)
    ver < GIT_MIN_VERSION &&
        throw(
        GitError(
            "bundled git at $exe reported version $ver; AgentRuleLint requires git >= $GIT_MIN_VERSION",
        ),
    )
    rt = (executable = exe, version = string(ver))
    tls[_TLS_RUNTIME] = rt
    return rt
end

function _git_executable_cmd(root::AbstractString)
    rt = git_runtime()
    if isempty(rt.executable)
        ensure_git_runtime!(root)
        rt = git_runtime()
    end
    return Cmd([rt.executable])
end

"""
    git_cmd(root, args...) -> Cmd

Build an isolated git command for `root` (`-C`, `safe.directory`, env isolation).
All AgentRuleLint and test git invocations must use this entry point.
"""
function _git_cmd_argv_prefix(root::AbstractString)
    r = abspath(String(root))
    empty_attrs = _git_global_config_path()
    prefix = String[
        "-C",
        r,
        "-c",
        "safe.directory=$(r)",
        "-c",
        "core.attributesFile=$(empty_attrs)",
    ]
    # Git_jll on macOS lacks a working UTF-8-MAC iconv (system git has one); git add on NFC
    # filenames fails with "precomposed unicode is not supported" without this setting.
    # core.precomposeunicode=false disables path normalization so bytes stay as written
    # (NFC stays NFC, NFD stays NFD; ls-files, plain check, and --diff agree). See
    # test/test_git_unicode_path_reporting.jl.
    Sys.isapple() && push!(prefix, "-c", "core.precomposeunicode=false")
    return prefix
end

function git_cmd(root::AbstractString, args::AbstractString...)
    base = _bundled_git_cmd()
    exe = String(base.exec[1])
    tail = Cmd(vcat(_git_cmd_argv_prefix(root), collect(String, args)))
    return setenv(`$exe $tail`, _git_merged_env(base))
end

"""Read stdout from an isolated git call; on failure raise `GitError` including stderr."""
function read_git_cmd(root::AbstractString, args::AbstractString...; error_prefix::AbstractString)
    return _read_git_cmd(git_cmd(root, args...); error_prefix = error_prefix)
end

"""Run an isolated git call (for tests and helpers)."""
function run_git_cmd(root::AbstractString, args::AbstractString...; cwd = nothing)
    cmd = git_cmd(root, args...)
    d = cwd === nothing ? root : String(cwd)
    return run(setenv(cmd; dir = d))
end

"""Read command stdout/stderr with deadlock-safe stderr drain (internal)."""
function _read_git_cmd(cmd::Cmd; error_prefix::AbstractString)
    out = Pipe()
    err = Pipe()
    proc = run(pipeline(cmd, stdout = out, stderr = err), wait = false)
    close(out.in)
    close(err.in)
    err_task = @async read(err)
    local stdout_data
    try
        stdout_data = read(out)
    catch
        fetch(err_task)
        rethrow()
    end
    stderr_data = fetch(err_task)
    wait(proc)
    if !success(proc)
        stderr_s = strip(String(stderr_data))
        detail = isempty(stderr_s) ? "exit $(proc.exitcode)" : "exit $(proc.exitcode): $stderr_s"
        throw(GitError("$error_prefix ($detail)"))
    end
    return stdout_data
end

function _git_toplevel(root::AbstractString)
    root = abspath(String(root))
    isdir(root) || throw(GitError("not a directory: $root"))
    return strip(String(read_git_cmd(root, "rev-parse", "--show-toplevel"; error_prefix = "not a git repository: $root")))
end

function _git_root(path::AbstractString)
    try
        return _git_toplevel(path)
    catch err
        err isa InterruptException && rethrow()
        err isa GitError && rethrow()
        throw(GitError("not a git repository: $(abspath(String(path))): $(format_error(err))"))
    end
end

function _git_feature_not_repository(root::AbstractString, feature::AbstractString)
    error_prefix = "$feature requires a git repository at $(abspath(String(root)))"
    try
        _git_toplevel(root)
    catch err
        err isa InterruptException && rethrow()
        err isa GitError && throw(GitError("$error_prefix ($(err.msg))"))
        throw(GitError("$error_prefix: $(format_error(err))"))
    end
    return nothing
end
