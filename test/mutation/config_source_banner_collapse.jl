include("mutation_lib.jl")

const _DETECT = _MUTATION_VERIFY_DETECTED_EXIT

run_source_mutation(;
    name = "human config-source banner collapses kinds",
    rel_path = "src/format/common.jl",
    needle = "    elseif cs.kind == ConfigSourceKind.BUILTIN\n        \"policy bundle base: builtin\"",
    replacement = join(
        [
            "    elseif cs.kind == ConfigSourceKind.BUILTIN",
            "        \"policy bundle base: \$(wire_name(ConfigSourceKind.PATH))\"",
        ],
        "\n",
    ),
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
        banners = String[]
        for (k, path, ref, sha) in (
                (AgentRuleLint.ConfigSourceKind.BUILTIN, "", "", ""),
                (AgentRuleLint.ConfigSourceKind.PATH, "", "", ""),
                (AgentRuleLint.ConfigSourceKind.GIT_REF, "", "main", "abc"),
            )
            cs = AgentRuleLint.ConfigSource(k, path, ref, sha)
            res = AgentRuleLint.CheckResult([v], true, 0, cs, AgentRuleLint.OutputFormat.HUMAN, 20, 0, 0)
            push!(banners, AgentRuleLint.human_policy_banner(res, "0.0.0"))
        end
        length(unique(banners)) == length(banners) || exit($_DETECT)
        """
        return mutation_verify_script(root, script; dir = root)
    end,
)
