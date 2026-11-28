using JSON: JSON

mutable struct _AnonymizerCounters
    id::Int
    str::Int
end

function _anonymize_ident!(s::AbstractString, ctr::_AnonymizerCounters)
    return Base.replace(
        s,
        r"\b[a-zA-Z_][a-zA-Z0-9_]*\b" => m -> begin
            if m == "end" || m == "function" || m == "if" || m == "using" || m == "module"
                return m
            end
            ctr.id += 1
            return m[1] in ('x', 'X') ? "x$(ctr.id)" : "f$(ctr.id)"
        end,
    )
end

function anonymize_snippet(source::AbstractString)
    ctr = _AnonymizerCounters(0, 0)
    s = _anonymize_ident!(source, ctr)
    return Base.replace(
        s,
        r"\"([^\"]*)\"" => _ -> begin
            ctr.str += 1
            return "\"s$(ctr.str)\""
        end,
    )
end

function _skeleton_walk!(parts::Vector{String}, node, pos)
    push!(parts, string(summary(node)))
    for (c, p) in _child_positions(node, pos)[1]
        JuliaSyntax.is_trivia(head(c)) && continue
        _skeleton_walk!(parts, c, p)
    end
    return nothing
end

function skeleton_ast_snippet(source::AbstractString)
    tree = parse_source(source)
    parts = String[]
    _skeleton_walk!(parts, tree, 1)
    return join(parts, "/")
end

function format_report(fingerprint::AbstractString, diagnostic::Violation, source::AbstractString)
    buf = IOBuffer()
    println(buf, JSON.json(ReportHeaderRecord()))
    println(buf, JSON.json(ReportRuleIdRecord(diagnostic.rule_id)))
    skel = skeleton_ast_snippet(source)
    lines = split(normalize_source(source), '\n')
    line =
        diagnostic.anchor_line <= length(lines) ? String(lines[diagnostic.anchor_line]) : String(source)
    anon = anonymize_snippet(line)
    println(
        buf,
        JSON.json(ReportSnippetRecord(String(fingerprint), pattern_hash(skel), anon)),
    )
    return String(take!(buf))
end

function _explain_extra(spec::RuleSpec, key::Symbol)
    return get(spec.extra, key, "")
end

function _explain_optional_block(label::AbstractString, body::AbstractString)
    isempty(strip(body)) && return ""
    return """

    $label:
    $(strip(body))"""
end

function format_explain_rule(spec::RuleSpec; enabled::Bool = true)
    anchor = _explain_extra(spec, :expect_anchor)
    example = _explain_extra(spec, :example)
    anchor_line = _explain_extra(spec, :anchor_line)
    syntax = _explain_extra(spec, :syntax)
    suppression = _explain_extra(spec, :suppression)
    intent_detail = _explain_extra(spec, :intent_detail)
    config = _explain_extra(spec, :config)
    detail = _explain_extra(spec, :detail)
    level_line = if enabled
        "level: $(wire_name(spec.level))"
    else
        "level: $(wire_name(spec.level)) (default when enabled)"
    end
    status_line = enabled ? "" : "\nstatus: not enabled in this config"
    body = """
    rule_id: $(spec.id)
    origin: $(origin_label(spec.origin))
    $(level_line)$(status_line)

    intent:
    $(spec.intent)

    do_not:
    $(spec.do_not)"""
    body *= _explain_optional_block("anchor_line", anchor_line)
    body *= _explain_optional_block("syntax", syntax)
    body *= _explain_optional_block("suppression", suppression)
    body *= _explain_optional_block("intent_detail", intent_detail)
    body *= _explain_optional_block("config", config)
    body *= _explain_optional_block("detail", detail)
    body *= """

    expect_anchor:
    $(isempty(anchor) ? "N/A." : anchor)

    example:
    $(isempty(example) ? "N/A." : example)"""
    return body
end

function format_explain_project_rule(pr::ProjectRule)
    rid = project_rule_id(pr)
    return """
    rule_id: $rid
    origin: [Project]
    level: $(wire_name(pr.level))

    intent:
    $(pr.intent)

    do_not:
    $(pr.do_not)

    expect_anchor:
    When using expect-audit suppression, reference `$rid` in `# agentrulelint-expect:` (same placement rules as expect-audit).

    example:
    # agentrulelint-expect: $rid reason="documented"
    x = "forbidden_literal"
    """
end

"""True when `id` is not a built-in `RuleDef` and not a declared `project/<id>`."""
function explain_rule_unknown(id::AbstractString; root::AbstractString = pwd())
    needle = String(strip(id))
    policy = resolve_policy(root)
    registry = build_builtin_registry(policy)
    if startswith(needle, "project/")
        short = needle[9:end]
        return !any(pr -> pr.id == short, policy.project_rules)
    end
    haskey(registry, needle) && return false
    return !haskey(RULE_DEFS_BY_ID, needle)
end

"""First built-in rule id under a known preset name, or `nothing`."""
function _preset_rule_id_hint(needle::AbstractString)
    needle == "shell-safety" && return SHELL_SAFETY_PRESET_ID
    needle == UNSAFE_BOUNDARY_STRICT_PRESET_ID && return UNSAFE_BOUNDARY_STRICT_PRESET_ID
    needle in KNOWN_PRESET_NAMES || return nothing
    prefix = needle * "/"
    for def in RULE_DEFS
        startswith(def.id, prefix) && return def.id
    end
    return nothing
end

"""Message for an unknown explain id; append a preset hint when applicable."""
function _explain_unknown_rule_message(needle::AbstractString)
    hint = _preset_rule_id_hint(needle)
    hint === nothing && return "unknown rule id: $needle"
    return "unknown rule id: $needle (did you mean $hint?)"
end

"""Explain a built-in or project rule.

Built-in ids resolve from `RULE_DEFS_BY_ID` even when the current config does
not enable them; inactive built-ins include
`status: not enabled in this config` and mark `level` as the default when
enabled. `unknown rule id` is reserved for ids that are neither built in nor
declared under `project_rules` (known preset names get a `did you mean` hint).
Does not affect `check`.
"""
function explain_rule(id::AbstractString; root::AbstractString = pwd())
    needle = String(strip(id))
    explain_rule_unknown(needle; root = root) &&
        throw(ArgumentError(_explain_unknown_rule_message(needle)))
    policy = resolve_policy(root)
    registry = build_builtin_registry(policy)
    if startswith(needle, "project/")
        short = needle[9:end]
        for pr in policy.project_rules
            pr.id == short && return format_explain_project_rule(pr)
        end
        throw(ArgumentError(_explain_unknown_rule_message(needle)))
    end
    if haskey(registry, needle)
        return format_explain_rule(registry[needle]; enabled = true)
    end
    def = RULE_DEFS_BY_ID[needle]
    spec = attach_rule_explain_docs(rule_def_to_spec(def))
    return format_explain_rule(spec; enabled = false)
end
