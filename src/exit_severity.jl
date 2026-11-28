"""Rank of a finding level for exit-threshold comparison (`warn` < `deny` < `forbid`)."""
function level_exit_rank(level::Level.T)
    level == Level.WARN && return 1
    level == Level.DENY && return 2
    level == Level.FORBID && return 3
    return 0
end

function _exit_severity_expected()
    return join((wire_name(x) for x in instances(Level.T) if x != Level.ALLOW), "|")
end

function _reject_allow_threshold(lvl::Level.T, raw, source::SeveritySource.T, label::AbstractString)
    lvl == Level.ALLOW || return lvl
    expected = _exit_severity_expected()
    if source == SeveritySource.CONFIG
        throw(ConfigError("unknown exit_severity '$raw' in $label (expected $expected)"))
    elseif source == SeveritySource.CLI
        throw(ArgumentError("unknown --exit-severity value '$raw' (expected $expected)"))
    end
    throw(InternalError("internal: unexpected severity source for allow rejection ($source)"))
end

function _level_parse_input(raw)
    raw isa AbstractString && return strip(String(raw))
    raw isa Symbol && return String(raw)
    return ""
end

"""Whether a diagnostic should set a non-zero exit code for `threshold` (`forbid`, `deny`, or `warn`).

Findings at level `forbid` always fail the check, regardless of threshold (integrity / expect-audit).
"""
function violation_counts_toward_exit(d::Violation, threshold::Level.T)
    is_violation_hit(d) || return false
    d.level == Level.FORBID && return true
    return level_exit_rank(d.level) >= level_exit_rank(threshold)
end

function check_exit_code(diags, threshold::Level.T)
    return any(d -> violation_counts_toward_exit(d, threshold), diags) ? 1 : 0
end

function _parse_exit_severity(raw, label::AbstractString)
    s = _level_parse_input(raw)
    isempty(s) && throw(ConfigError("missing exit_severity in $label"))
    local lvl
    try
        lvl = parse_enum(Level.T, s)
    catch err
        err isa ConfigError || rethrow()
        throw(
            ConfigError(
                "unknown exit_severity '$raw' in $label (expected $(_exit_severity_expected()))",
            ),
        )
    end
    return _reject_allow_threshold(lvl, raw, SeveritySource.CONFIG, label)
end

function _parse_exit_severity_cli(raw)
    raw isa Level.T && return _reject_allow_threshold(raw, wire_name(raw), SeveritySource.CLI, "")
    s = _level_parse_input(raw)
    local lvl
    try
        lvl = parse_enum(Level.T, s)
    catch err
        err isa ConfigError || rethrow()
        throw(
            ArgumentError(
                "unknown --exit-severity value '$raw' (expected $(_exit_severity_expected()))",
            ),
        )
    end
    return _reject_allow_threshold(lvl, raw, SeveritySource.CLI, "")
end

"""Return `(threshold, threshold_source, baseline, baseline_source)`."""
function resolve_exit_severity(policy::PolicyBundle; exit_severity = nothing)
    baseline = policy.exit_severity
    baseline_src = policy.exit_severity_source
    if exit_severity === nothing
        return baseline, baseline_src, baseline, baseline_src
    end
    return _parse_exit_severity_cli(exit_severity), SeveritySource.CLI, baseline, baseline_src
end
