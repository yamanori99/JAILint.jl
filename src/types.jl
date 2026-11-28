# Immutable value types for AgentRuleLint (parse-don't-validate).

struct Span
    start_line::Int
    start_col::Int
    end_line::Int
    end_col::Int
end

Span() = Span(0, 0, 0, 0)

function Base.isless(a::Span, b::Span)
    return (a.start_line, a.start_col, a.end_line, a.end_col) <
        (b.start_line, b.start_col, b.end_line, b.end_col)
end

struct ConfigSource
    kind::ConfigSourceKind.T
    path::String
    ref::String
    sha::String
end

ConfigSource() = ConfigSource(ConfigSourceKind.BUILTIN, "", "", "")

function config_source_dict(cs::ConfigSource)
    d = Dict{String, Any}("kind" => wire_name(cs.kind))
    !isempty(cs.path) && (d["path"] = cs.path)
    !isempty(cs.ref) && (d["ref"] = cs.ref)
    !isempty(cs.sha) && (d["sha"] = cs.sha)
    return d
end

"""Single lint finding (`rule_id` is always a canonical slug)."""
struct Violation
    rule_id::String
    origin::Origin.T
    level::Level.T
    path::String
    span::Span
    anchor_line::Int
    fingerprint::String
    expect_status::ExpectStatus.T
    suppressed::Bool
    message::String
    intent::String
    do_not::String
end

struct CeilingEntry
    violations::Dict{String, Dict{String, Int}}
    expects::Dict{String, Dict{String, Int}}
end

function Base.isequal(a::CeilingEntry, b::CeilingEntry)
    return isequal(a.violations, b.violations) && isequal(a.expects, b.expects)
end

Base.:(==)(a::CeilingEntry, b::CeilingEntry) = isequal(a, b)

const DEFAULT_EXIT_SEVERITY = Level.WARN

function _check_below_threshold_invariant(
        below_threshold_count::Int,
        below_threshold_level::Union{Nothing, Level.T},
        below_threshold_mixed::Bool,
    )
    if below_threshold_count <= 0
        below_threshold_level === nothing || throw(
            InternalError("below_threshold_count == 0 requires below_threshold_level === nothing"),
        )
        below_threshold_mixed && throw(
            InternalError("below_threshold_count == 0 requires below_threshold_mixed == false"),
        )
        return
    end
    if below_threshold_mixed
        below_threshold_level === nothing || throw(
            InternalError("below_threshold_mixed requires below_threshold_level === nothing"),
        )
        return
    end
    below_threshold_level === nothing && throw(
        InternalError(
            "homogeneous below-threshold findings require below_threshold_level",
        ),
    )
    return
end

struct CheckResult
    violations::Vector{Violation}
    complete::Bool
    exit_code::Int
    config_source::ConfigSource
    default_format::OutputFormat.T
    max_hits_per_rule::Int
    suppressed_count::Int
    violation_count::Int
    ceilings::CeilingEntry
    exit_severity::Level.T
    exit_severity_source::SeveritySource.T
    baseline_exit_severity::Level.T
    baseline_exit_severity_source::SeveritySource.T
    below_threshold_count::Int
    below_threshold_level::Union{Nothing, Level.T}
    below_threshold_mixed::Bool
    git_executable::String
    git_version::String

    function CheckResult(
            violations::Vector{Violation},
            complete::Bool,
            exit_code::Int,
            config_source::ConfigSource,
            default_format::OutputFormat.T,
            max_hits_per_rule::Int,
            suppressed_count::Int,
            violation_count::Int;
            ceilings::CeilingEntry = CeilingEntry(Dict(), Dict()),
            exit_severity::Level.T = DEFAULT_EXIT_SEVERITY,
            exit_severity_source::SeveritySource.T = SeveritySource.DEFAULT,
            baseline_exit_severity::Level.T = DEFAULT_EXIT_SEVERITY,
            baseline_exit_severity_source::SeveritySource.T = SeveritySource.DEFAULT,
            below_threshold_count::Int = 0,
            below_threshold_level::Union{Nothing, Level.T} = nothing,
            below_threshold_mixed::Bool = false,
            git_executable::String = "",
            git_version::String = "",
        )
        _check_below_threshold_invariant(below_threshold_count, below_threshold_level, below_threshold_mixed)
        return new(
            violations,
            complete,
            exit_code,
            config_source,
            default_format,
            max_hits_per_rule,
            suppressed_count,
            violation_count,
            ceilings,
            exit_severity,
            exit_severity_source,
            baseline_exit_severity,
            baseline_exit_severity_source,
            below_threshold_count,
            below_threshold_level,
            below_threshold_mixed,
            git_executable,
            git_version,
        )
    end
end

function Base.isequal(a::CheckResult, b::CheckResult)
    return all(f -> isequal(getfield(a, f), getfield(b, f)), fieldnames(CheckResult))
end

Base.:(==)(a::CheckResult, b::CheckResult) = isequal(a, b)

struct ConfigError <: Exception
    msg::String
end

struct GitError <: Exception
    msg::String
end

struct ParseError <: Exception
    msg::String
end

"""Unexpected internal failure, optionally with a concrete catch backtrace for CLI dump.

The wrapped exception is already stringified into `msg` (`format_error`); only the
backtrace is retained separately so fields stay concrete for JETLS.
"""
struct InternalError <: Exception
    msg::String
    bt::Vector{Base.StackTraces.StackFrame}
end

InternalError(msg::AbstractString) = InternalError(String(msg), Base.StackTraces.StackFrame[])

function Base.showerror(io::IO, e::InternalError)
    return print(io, e.msg)
end

"""Dedicated constant-fold step-budget overflow (not an `ArgumentError`)."""
struct FoldBudgetExceeded <: Exception
    limit::Int
end

function Base.showerror(io::IO, e::FoldBudgetExceeded)
    return print(io, "constant fold step budget exceeded (limit ", e.limit, ")")
end

"""Single stringification for user-facing and logged errors."""
format_error(err) = sprint(showerror, err)

struct RuleSpec
    id::String
    origin::Origin.T
    level::Level.T
    intent::String
    do_not::String
    extra::Dict{Symbol, String}
end

"""One built-in or preset rule: identity, defaults, and registration metadata.

`source_file` / `test_file` are basenames under `src/rules/` and `test/`.
`coverage_paths` are repo-relative paths that must exist (corpus or fixture coverage).
"""
struct RuleDef
    id::String
    origin::Origin.T
    default_level::Level.T
    intent::String
    do_not::String
    extra::Dict{Symbol, String}
    source_file::String
    test_file::String
    coverage_paths::Tuple{Vararg{String}}
end

function rule_def_to_spec(def::RuleDef)
    return RuleSpec(def.id, def.origin, def.default_level, def.intent, def.do_not, copy(def.extra))
end

struct ShellSafetyConfig
    active::Bool
    level::Level.T
    intent::String
    do_not::String
end

ShellSafetyConfig() = ShellSafetyConfig(false, Level.DENY, "", "")

struct UnsafeBoundaryStrictConfig
    active::Bool
    level::Level.T
    intent::String
    do_not::String
end

UnsafeBoundaryStrictConfig() = UnsafeBoundaryStrictConfig(false, Level.WARN, "", "")

struct ProjectRule
    id::String
    level::Level.T
    paths::Vector{String}
    path_regexes::Vector{Regex}
    forbid_literals::Vector{String}
    intent::String
    do_not::String
end

struct UnsafeBoundaryConfig
    active::Bool
    level::Level.T
    allow_modules::Vector{String}
    allow_globs::Vector{Regex}
    intent::String
    do_not::String
end

UnsafeBoundaryConfig() = UnsafeBoundaryConfig(false, Level.WARN, String[], Regex[], "", "")

struct ProtectedGlobEntry
    regex::Regex
    reason::String
    change_types::Union{Nothing, Set{String}}
end
struct PolicyBundle
    agentrulelint_version::VersionNumber
    default_format::OutputFormat.T
    exit_severity::Level.T
    exit_severity_source::SeveritySource.T
    max_hits_per_rule::Int
    presets::Vector{String}
    rules::Dict{String, RuleSpec}
    project_rules::Vector{ProjectRule}
    on_allow_rule::Level.T
    shell_safety::ShellSafetyConfig
    unsafe_boundary::UnsafeBoundaryConfig
    unsafe_boundary_strict::UnsafeBoundaryStrictConfig
    config_path::String
    config_source::ConfigSource
    project_toml_policy::String
    protected_path_globs::Vector{ProtectedGlobEntry}
end

struct ExpectLine
    line::Int
    rule_ref::String
    reason::String
    raw::String
end

struct ParsedFile
    path::String
    source::String
    normalized::String
end

"""Per-file lint context. `tree` is the shared `GreenNode` for `.jl` head sources (`nothing` otherwise)."""
struct FileContext
    parsed::ParsedFile
    tree::Union{Nothing, JuliaSyntax.GreenNode{JuliaSyntax.SyntaxHead}}
    expects::Vector{ExpectLine}
    expect_errors::Vector{Violation}
end

struct RuleRunContext
    root::String
    policy::PolicyBundle
    ceilings::CeilingEntry
    files::Vector{FileContext}
    parser_rev::String
end

struct FoldedStringExpr
    value::String
    byte_start::Int
    byte_end::Int
end

"""Result of a constant-fold collection walk (`budget_exceeded` means analysis was truncated).

`at_byte` is the last fold-walk byte offset when the budget was exhausted (1 if not).
"""
struct FoldCollectResult
    folds::Vector{FoldedStringExpr}
    budget_exceeded::Bool
    at_byte::Int
end

FoldCollectResult(folds::Vector{FoldedStringExpr}, budget_exceeded::Bool) =
    FoldCollectResult(folds, budget_exceeded, 1)

const KEBAB_ID = r"^[a-z][a-z0-9]*(-[a-z0-9]+)*$"

function validate_kebab_rule_id(id::AbstractString, label::AbstractString)
    s = String(id)
    occursin('/', s) && throw(ConfigError("$label: id must not contain '/' ($(s))"))
    match(KEBAB_ID, s) === nothing &&
        throw(ConfigError("$label: invalid kebab-case id ($(s))"))
    return s
end

is_fail_closed(err) =
    err isa ConfigError || err isa GitError || err isa ParseError

function origin_label(o::Origin.T)::String
    if o == Origin.AGENTRULELINT
        return "[AgentRuleLint]"
    elseif o == Origin.PRESET
        return "[Preset]"
    elseif o == Origin.PROJECT
        return "[Project]"
    else
        throw(InternalError("internal: unknown origin $o"))
    end
end

rule_display_id(r::RuleSpec) = r.id
project_rule_id(pr::ProjectRule) = "project/$(pr.id)"

function rule_ref_matches(rule_ref::String, diagnostic_rule_id::String)
    r = strip(rule_ref)
    d = strip(diagnostic_rule_id)
    r == d && return true
    d == "project/$r" && return true
    return false
end

function is_forbid_rule(policy::PolicyBundle, rule_ref::String)
    r = strip(rule_ref)
    for (_, spec) in policy.rules
        (spec.id == r || r == spec.id) && spec.level == Level.FORBID && return true
    end
    for pr in policy.project_rules
        (r == pr.id || r == project_rule_id(pr)) && pr.level == Level.FORBID && return true
    end
    return false
end
