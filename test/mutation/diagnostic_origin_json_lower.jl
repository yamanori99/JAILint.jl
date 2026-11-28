include("mutation_lib.jl")

const _DETECT = _MUTATION_VERIFY_DETECTED_EXIT

run_source_mutation(;
    name = "DiagnosticRecord Origin JSON lower uses Julia symbol name",
    rel_path = "src/format/records.jl",
    needle = "StructUtils.lower(::JSONStyle, x::Origin.T) = wire_name(x)",
    replacement = "StructUtils.lower(::JSONStyle, x::Origin.T) = string(Symbol(x))",
    verify = root -> begin
        script = """
        using AgentRuleLint, JSON
        d = AgentRuleLint.Violation(
            "expect-audit",
            AgentRuleLint.Origin.AGENTRULELINT,
            AgentRuleLint.Level.FORBID,
            "test/corpus/block_expect.jl",
            AgentRuleLint.Span(1, 1, 60, 1),
            1,
            "v1:deadbeef",
            AgentRuleLint.ExpectStatus.UNFULFILLED,
            false,
            "msg",
            "",
            "",
        )
        cs = AgentRuleLint.ConfigSource()
        res = AgentRuleLint.CheckResult([d], true, 1, cs, AgentRuleLint.OutputFormat.JSON, 20, 0, 1)
        line = JSON.json(AgentRuleLint.DiagnosticRecord(d))
        occursin("\\"origin\\":\\"agentrulelint\\"", line) || exit($_DETECT)
        js = AgentRuleLint.format_json(res)
        occursin("\\"origin\\":\\"agentrulelint\\"", js) || exit($_DETECT)
        """
        return mutation_verify_script(root, script; dir = root)
    end,
)
