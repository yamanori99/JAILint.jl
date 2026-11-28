# Built-in `analysis-incomplete`: fail-closed when static analysis truncates
# (e.g. constant-fold step budget). Integrity forbid; never expect-suppressible.

const ANALYSIS_INCOMPLETE_MSG_PREFIX = "analysis incomplete: constant-fold budget exceeded"

function analysis_incomplete_message(path::AbstractString, analyzer::AbstractString)
    return "$ANALYSIS_INCOMPLETE_MSG_PREFIX in $path ($analyzer)"
end

function is_analysis_incomplete(d::Violation)
    return d.rule_id == ANALYSIS_INCOMPLETE_RULE
end

function _analysis_incomplete_docs(policy::PolicyBundle)
    spec = get(policy.rules, ANALYSIS_INCOMPLETE_RULE, nothing)
    if spec === nothing
        return ANALYSIS_INCOMPLETE_RULE_DEF.intent, ANALYSIS_INCOMPLETE_RULE_DEF.do_not
    end
    intent = isempty(spec.intent) ? ANALYSIS_INCOMPLETE_RULE_DEF.intent : spec.intent
    do_not = isempty(spec.do_not) ? ANALYSIS_INCOMPLETE_RULE_DEF.do_not : spec.do_not
    return intent, do_not
end

"""Push a `:forbid` `analysis-incomplete` finding (constant-fold budget exhaustion).

`analyzer` names the folding call site (e.g. `project/<id>`, `test-integrity`,
`shell-safety/process-pattern`). Skips if `diags` already has a finding for `path`.
"""
function push_analysis_incomplete!(
        diags::Vector{Violation},
        policy::PolicyBundle,
        path::String,
        source::AbstractString,
        byte_start::Int,
        byte_end::Int,
        analyzer::AbstractString,
    )
    any(d -> is_analysis_incomplete(d) && d.path == path, diags) && return nothing
    intent, do_not = _analysis_incomplete_docs(policy)
    sp = span_from_byte_range(source, byte_start, byte_end)
    push!(
        diags,
        Violation(
            ANALYSIS_INCOMPLETE_RULE,
            Origin.AGENTRULELINT,
            Level.FORBID,
            path,
            sp,
            sp.start_line,
            "",
            ExpectStatus.NONE,
            false,
            analysis_incomplete_message(path, analyzer),
            intent,
            do_not,
        ),
    )
    return nothing
end

"""Approximate source coverage of `sp` (same-line column width, else multi-line).

Used only to rank competing `analysis-incomplete` findings for one path.
"""
function _span_extent(sp::Span)
    if sp.end_line == sp.start_line
        return max(0, sp.end_col - sp.start_col)
    end
    # Multi-line spans outrank any single-line width we emit for fold budgets.
    return typemax(Int) ÷ 4 + max(0, sp.end_line - sp.start_line)
end

"""Return true when `new` should replace `old` for the same path.

Priority (explicit):
1. Wider span wins — prefer a syntactic construct (e.g. test-integrity's
   `@test` macrocall) over a 1-byte fold-walk cursor from project / shell-safety.
2. On equal extent, prefer the earlier start `(line, col)`.
3. Otherwise keep `old` (first wins; stable).
"""
function _prefer_analysis_incomplete(new::Violation, old::Violation)
    en = _span_extent(new.span)
    eo = _span_extent(old.span)
    en != eo && return en > eo
    sn = (new.span.start_line, new.span.start_col)
    so = (old.span.start_line, old.span.start_col)
    sn != so && return sn < so
    return false
end

"""Keep one `analysis-incomplete` finding per path; see `_prefer_analysis_incomplete`."""
function dedupe_analysis_incomplete!(diags::Vector{Violation})
    best = Dict{String, Int}()
    drop = Set{Int}()
    for (i, d) in enumerate(diags)
        is_analysis_incomplete(d) || continue
        if haskey(best, d.path)
            j = best[d.path]
            prev = diags[j]
            if _prefer_analysis_incomplete(d, prev)
                push!(drop, j)
                best[d.path] = i
            else
                push!(drop, i)
            end
        else
            best[d.path] = i
        end
    end
    isempty(drop) && return diags
    return Violation[d for (i, d) in enumerate(diags) if !(i in drop)]
end

const _ANALYSIS_INCOMPLETE_EXPLAIN_DETAIL = """
Emitted when a constant-fold walk hits the shared step budget (`FOLD_MAX_STEPS`)
before finishing. Call sites include project-rule literal folding, shell-safety Cmd
folding, and test-integrity `@test` value folding. The finding is integrity
`forbid` and cannot be suppressed with `# agentrulelint-expect:`. At most one
finding is reported per file (wider syntactic span preferred over a fold-walk
point cursor); the message names the analyzer. Fix by simplifying the expression
(shorter concatenations or `@test` chains) so static folding can finish.
"""

function analysis_incomplete_explain_extra()
    return Dict{Symbol, String}(:detail => strip(_ANALYSIS_INCOMPLETE_EXPLAIN_DETAIL))
end

const ANALYSIS_INCOMPLETE_RULE_DEF = RuleDef(
    ANALYSIS_INCOMPLETE_RULE,
    Origin.AGENTRULELINT,
    Level.FORBID,
    "Fail closed when static analysis cannot finish (constant-fold budget).",
    "Pad files with enough folds to exhaust the budget and hide later findings, or suppress the incomplete diagnostic.",
    Dict{Symbol, String}(),
    "analysis_incomplete.jl",
    "test_analysis_incomplete.jl",
    ("test/corpus/test_integrity_fold_budget.jl",),
)
