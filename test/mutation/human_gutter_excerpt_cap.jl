include("mutation_lib.jl")

const _DETECT = _MUTATION_VERIFY_DETECTED_EXIT

run_source_mutation(;
    name = "human gutter excerpt cap",
    rel_path = "src/format/common.jl",
    needle = "excerpt, omit_suffix, _ = _human_gutter_excerpt(line)",
    replacement = "excerpt, omit_suffix, _ = line, \"\", 0",
    verify = root -> begin
        script = """
        using AgentRuleLint
        root = normpath(joinpath(dirname(pathof(AgentRuleLint)), ".."))
        path = joinpath("test", "corpus", "test_integrity_fold_budget.jl")
        res = AgentRuleLint.check(root; paths = [path])
        io = IOContext(IOBuffer(), :color => false)
        out = AgentRuleLint.format_human(res; root = root, io = io)
        for line in split(out, '\\n'; keepempty = false)
            occursin("> ", line) || continue
            length(line) > 1000 ? exit($_DETECT) : exit(0)
        end
        exit(0)
        """
        return mutation_verify_script(root, script; dir = root)
    end,
)

run_source_mutation(;
    name = "human gutter underline width",
    rel_path = "src/format/common.jl",
    needle = "println(buf, string(ul_prefix, ul_display))",
    replacement = "println(buf, _human_truncate_code(ul_display, ul_prefix, width))",
    verify = root -> begin
        script = """
        using AgentRuleLint
        root = normpath(joinpath(dirname(pathof(AgentRuleLint)), ".."))
        path = joinpath("test", "corpus", "expect_anchor_mismatch.jl")
        res = AgentRuleLint.check(root; paths = [path])
        io = IOContext(IOBuffer(), :color => false)
        out = AgentRuleLint.format_human(res; root = root, io = io, output_width = 80)
        ul_prefix = AgentRuleLint.HUMAN_UNDERLINE_PREFIX
        code_prefix = AgentRuleLint.HUMAN_CODE_PREFIX
        lines = split(out, '\\n'; keepempty = false)
        for (i, line) in enumerate(lines)
            s = AgentRuleLint.strip_ansi(line)
            startswith(s, code_prefix) || continue
            body = s[(length(code_prefix) + 1):end]
            occursin(" (+", body) && (body = split(body, " (+"; limit = 2)[1])
            body = rstrip(body)
            for j in (i + 1):length(lines)
                ul = lines[j]
                ul_s = AgentRuleLint.strip_ansi(ul)
                if startswith(ul_s, code_prefix)
                    break
                end
                startswith(ul_s, ul_prefix) || continue
                occursin('~', ul) || continue
                ub = rstrip(ul_s[(length(ul_prefix) + 1):end])
                if endswith(ub, "…") && !endswith(body, "…")
                    exit($_DETECT)
                end
                break
            end
        end
        exit(0)
        """
        return mutation_verify_script(root, script; dir = root)
    end,
)
