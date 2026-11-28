# Shared helpers for built-in / preset rule runners.

function _effective_rule_level(policy::PolicyBundle, level::Level.T)
    level == Level.ALLOW && return policy.on_allow_rule
    return level
end

function _push_builtin_violation!(
        diags::Vector{Violation},
        rule_id::String,
        origin::Origin.T,
        eff_level::Level.T,
        path::String,
        source::AbstractString,
        byte_start::Int,
        byte_end::Int,
        msg::String,
        intent::String,
        do_not::String,
    )
    sp = span_from_byte_range(source, byte_start, byte_end)
    push!(
        diags,
        Violation(
            rule_id,
            origin,
            eff_level,
            path,
            sp,
            sp.start_line,
            "",
            ExpectStatus.NONE,
            false,
            msg,
            intent,
            do_not,
        ),
    )
    return nothing
end
