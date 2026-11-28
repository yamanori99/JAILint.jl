include("mutation_lib.jl")

const _ON_FILTER_DELETE_DETECTOR =
    "test/mutation/detectors/protected_paths_on_filter_delete_detector.jl"

assert_detector_alive(_julia_project_cmd(MUTATION_ROOT, _ON_FILTER_DELETE_DETECTOR))

run_source_mutation(;
    name = "protected-paths on filter fail-open",
    rel_path = "src/rules/protected_paths.jl",
    needle = """
    function _on_allows(change_types::Union{Nothing, Set{String}}, word::AbstractString)
        change_types === nothing && return true
        return String(word) in change_types
    end
    """,
    replacement = """
    function _on_allows(change_types::Union{Nothing, Set{String}}, word::AbstractString)
        return false
    end
    """,
    verify = root -> begin
        cmd = _julia_project_cmd(root, _ON_FILTER_DELETE_DETECTOR)
        return detector_disabled(cmd; dir = root)
    end,
)
