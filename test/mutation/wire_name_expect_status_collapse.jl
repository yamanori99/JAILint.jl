include("mutation_lib.jl")

const _DETECT = _MUTATION_VERIFY_DETECTED_EXIT

run_source_mutation(;
    name = "wire_name ExpectStatus maps two members to same label",
    rel_path = "src/enums.jl",
    needle = "function wire_name(x::ExpectStatus.T)::String\n    return lowercase(String(Symbol(x)))\nend",
    replacement = join(
        [
            "function wire_name(x::ExpectStatus.T)::String",
            "    x == ExpectStatus.FULFILLED && return \"fulfilled\"",
            "    x == ExpectStatus.UNFULFILLED && return \"fulfilled\"",
            "    return lowercase(String(Symbol(x)))",
            "end",
        ],
        "\n",
    ),
    verify = root -> begin
        script = """
        using AgentRuleLint
        labs = AgentRuleLint.wire_name.(instances(AgentRuleLint.ExpectStatus.T))
        length(unique(labs)) == length(labs) || exit($_DETECT)
        """
        return mutation_verify_script(root, script; dir = root)
    end,
)
