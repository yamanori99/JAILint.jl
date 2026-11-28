const SILENT_CATCH_ID = "silent-catch"

function _silent_catch_warn_counts(rule::RuleSpec)
    return get(rule.extra, :warn_counts_as_handling, "false") == "true"
end

function _push_silent_catch_violation!(
        diags::Vector{Violation},
        rule::RuleSpec,
        path::String,
        source::AbstractString,
        site::TryCatchSite,
        msg::String,
    )
    _, sp = span_for_line(source, site.try_line)
    push!(
        diags,
        Violation(
            SILENT_CATCH_ID,
            rule.origin,
            rule.level,
            path,
            sp,
            site.try_line,
            "",
            ExpectStatus.NONE,
            false,
            msg,
            rule.intent,
            rule.do_not,
        ),
    )
    return nothing
end

function run_silent_catch(fc::FileContext, policy::PolicyBundle)
    rule = get(policy.rules, SILENT_CATCH_ID, nothing)
    rule === nothing && return Violation[]
    rule.level == Level.ALLOW && return Violation[]
    path = fc.parsed.path
    source = fc.parsed.normalized
    tree = fc.tree
    tree === nothing && return Violation[]
    warn_counts = _silent_catch_warn_counts(rule)
    diags = Violation[]
    for site in collect_try_catch_sites(tree, source)
        body = site.catch_body
        body === nothing && continue
        swallows = catch_swallows_exception(
            body,
            site.catch_body_pos,
            source,
            site.catch_var;
            warn_counts_as_handling = warn_counts,
        )
        swallows || continue
        dodge = catch_var_dodge_name(site.catch_var)
        msg = dodge ?
            "catch binding uses a leading-underscore name but does not rethrow or throw" :
            "catch block swallows exceptions without rethrow or throw on unhandled paths"
        _push_silent_catch_violation!(diags, rule, path, source, site, msg)
    end
    return diags
end

const _SILENT_CATCH_EXPLAIN_ANCHOR = """
The `try` keyword line of the `try`/`catch` (or `try`/`catch`/`finally`) expression.
"""

const _SILENT_CATCH_EXPLAIN_DETAIL = """
Flags catch-all handlers whose body does not rethrow or throw on unhandled paths: empty catch,
assignments or `nothing` only, log-only handlers, and `if` branches without a propagating `else`.

Legitimate patterns include `e isa T || rethrow()`, `if e isa T ... else rethrow() end`,
unconditional `rethrow()` / `throw(...)`, and `err isa InterruptException && rethrow()`
followed by a typed `throw`.

Configure whether `@warn ... exception=...` alone counts as handling via
`[rules.silent-catch]` `warn_counts_as_handling` (default: false).
"""

function silent_catch_explain_extra()
    return Dict{Symbol, String}(
        :anchor_line => strip(_SILENT_CATCH_EXPLAIN_ANCHOR),
        :detail => strip(_SILENT_CATCH_EXPLAIN_DETAIL),
    )
end

const SILENT_CATCH_RULE_DEF = RuleDef(
    SILENT_CATCH_ID,
    Origin.AGENTRULELINT,
    Level.WARN,
    "Surface try/catch blocks that hide failures instead of rethrowing or throwing on unhandled paths.",
    "Use empty catch bodies, log-only handlers, or partial branches without rethrow to silence errors.",
    Dict{Symbol, String}(:warn_counts_as_handling => "false"),
    "silent_catch.jl",
    "test_silent_catch.jl",
    ("test/corpus/silent_catch_empty.jl",),
)
