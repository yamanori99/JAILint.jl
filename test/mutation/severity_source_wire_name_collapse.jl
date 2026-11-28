include("mutation_lib.jl")

const _DETECT = _MUTATION_VERIFY_DETECTED_EXIT

run_source_mutation(;
    name = "SeveritySource wire_name collapses distinct members",
    rel_path = "src/enums.jl",
    needle = "function wire_name(x::SeveritySource.T)::String\n    return lowercase(String(Symbol(x)))\nend",
    replacement = "function wire_name(x::SeveritySource.T)::String\n    return \"default\"\nend",
    verify = root -> begin
        script = """
        using AgentRuleLint
        w = AgentRuleLint.wire_name.(instances(AgentRuleLint.SeveritySource.T))
        length(unique(w)) == length(w) || exit($_DETECT)
        """
        return mutation_verify_script(root, script; dir = root)
    end,
)
