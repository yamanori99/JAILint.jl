include("mutation_lib.jl")

const _DETECT = _MUTATION_VERIFY_DETECTED_EXIT

run_source_mutation(;
    name = "below_threshold_phrase ignores mixed flag",
    rel_path = "src/format/common.jl",
    needle = "    result.below_threshold_mixed && return \"\$n \$word below threshold\"",
    replacement = "    false && result.below_threshold_mixed && return \"\$n \$word below threshold\"",
    verify = root -> begin
        script = """
        using AgentRuleLint
        v = AgentRuleLint.Violation(
            "agentrulelint/test",
            AgentRuleLint.Origin.AGENTRULELINT,
            AgentRuleLint.Level.WARN,
            "x.jl",
            AgentRuleLint.Span(1, 1, 1, 1),
            1,
            "fp",
            AgentRuleLint.ExpectStatus.NONE,
            false,
            "m",
            "i",
            "d",
        )
        res = AgentRuleLint.CheckResult(
            [v],
            true,
            0,
            AgentRuleLint.ConfigSource(),
            AgentRuleLint.OutputFormat.HUMAN,
            20,
            0,
            0;
            below_threshold_count = 3,
            below_threshold_mixed = true,
        )
        phrase = AgentRuleLint.verdict_exit_paren(res)
        occursin("below threshold", phrase) || exit($_DETECT)
        """
        return mutation_verify_script(root, script; dir = root)
    end,
)
