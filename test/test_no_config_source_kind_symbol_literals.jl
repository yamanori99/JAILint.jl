# Guard: `src/` must not use `:builtin` / `:path` / `:git_ref` quote literals
# outside conversion functions (issue #104 PR 4). Shares scan with level/origin guards.
# `:path` is included; unrelated symbols (`:paths`, `:config_path`, field `cs.path`) are different.

include(joinpath(@__DIR__, "enum_symbol_guard_common.jl"))
using .EnumSymbolGuard: scan_enum_symbol_source, collect_src_enum_symbol_violations

const _CONFIG_SOURCE_PROBE_REL = "src/__config_source_kind_symbol_guard_probe__.jl"
const _CONFIG_SOURCE_KIND_NAMES = Set(["builtin", "path", "git_ref"])
const _CONFIG_SOURCE_KIND_ALLOWLIST = Tuple{String, String, String}[]

@testset "src/ ConfigSourceKind Symbol literal guard" begin
    @testset "syntax scan finds quote literals (probe sources)" begin
        v, _ = scan_enum_symbol_source(_CONFIG_SOURCE_PROBE_REL, "x = :builtin\n", _CONFIG_SOURCE_KIND_NAMES, _CONFIG_SOURCE_KIND_ALLOWLIST)
        @test any(x -> x[3] == "builtin", v)
        v, _ = scan_enum_symbol_source(_CONFIG_SOURCE_PROBE_REL, "x == :git_ref\n", _CONFIG_SOURCE_KIND_NAMES, _CONFIG_SOURCE_KIND_ALLOWLIST)
        @test any(x -> x[3] == "git_ref", v)
        v, _ = scan_enum_symbol_source(_CONFIG_SOURCE_PROBE_REL, "get(k, :paths, [])\n", _CONFIG_SOURCE_KIND_NAMES, _CONFIG_SOURCE_KIND_ALLOWLIST)
        @test isempty(v)
        comment_only = "# :path\n"
        v, _ = scan_enum_symbol_source(_CONFIG_SOURCE_PROBE_REL, comment_only, _CONFIG_SOURCE_KIND_NAMES, _CONFIG_SOURCE_KIND_ALLOWLIST)
        @test isempty(v)
        str_only = "s = \":builtin\"\n"
        v, _ = scan_enum_symbol_source(_CONFIG_SOURCE_PROBE_REL, str_only, _CONFIG_SOURCE_KIND_NAMES, _CONFIG_SOURCE_KIND_ALLOWLIST)
        @test isempty(v)
        convert_fn = "function wire_name(x::ConfigSourceKind.T)\n    x == :path && return \"p\"\n    return \"\"\nend\n"
        v, _ = scan_enum_symbol_source(_CONFIG_SOURCE_PROBE_REL, convert_fn, _CONFIG_SOURCE_KIND_NAMES, _CONFIG_SOURCE_KIND_ALLOWLIST)
        @test isempty(v)
    end

    violations, used = collect_src_enum_symbol_violations(ROOT, _CONFIG_SOURCE_KIND_NAMES, _CONFIG_SOURCE_KIND_ALLOWLIST)
    for (file, line, name, snippet) in violations
        @error "ConfigSourceKind Symbol literal outside conversion functions / allowlist" file line name snippet
    end
    @test isempty(violations)

    stale = [(f, id) for (f, id, _) in _CONFIG_SOURCE_KIND_ALLOWLIST if (f, id) ∉ used]
    @test isempty(stale) || error(
        "allowlist entries with no use in src/: $(join(["$f:$id" for (f, id) in stale], ", "))",
    )
end
