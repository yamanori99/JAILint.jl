# Guard: `src/` must not use SeveritySource quote literals outside conversion functions (issue #104 PR 6).

include(joinpath(@__DIR__, "enum_symbol_guard_common.jl"))
using .EnumSymbolGuard: scan_enum_symbol_source, collect_src_enum_symbol_violations

const _SEVERITY_SOURCE_PROBE_REL = "src/__severity_source_symbol_guard_probe__.jl"
const _SEVERITY_SOURCE_NAMES = Set(["default", "config", "cli"])
const _SEVERITY_SOURCE_SYMBOL_ALLOWLIST = [
    ("src/format/report.jl", "config", "explain extra dict key"),
    ("src/rules/shell_safety.jl", "config", "explain extra dict key"),
    ("src/rules/unsafe_boundary.jl", "config", "explain extra dict key"),
    ("src/rules/unsafe_boundary_strict.jl", "config", "explain extra dict key"),
]

@testset "src/ SeveritySource Symbol literal guard" begin
    @testset "syntax scan finds quote literals (probe sources)" begin
        v, _ = scan_enum_symbol_source(_SEVERITY_SOURCE_PROBE_REL, "x = :default\n", _SEVERITY_SOURCE_NAMES, _SEVERITY_SOURCE_SYMBOL_ALLOWLIST)
        @test any(x -> x[3] == "default", v)
        v, _ = scan_enum_symbol_source(_SEVERITY_SOURCE_PROBE_REL, "x == :cli\n", _SEVERITY_SOURCE_NAMES, _SEVERITY_SOURCE_SYMBOL_ALLOWLIST)
        @test any(x -> x[3] == "cli", v)
        convert_fn = "function wire_name(x::SeveritySource.T)\n    x == :config && return \"c\"\n    return \"\"\nend\n"
        v, _ = scan_enum_symbol_source(_SEVERITY_SOURCE_PROBE_REL, convert_fn, _SEVERITY_SOURCE_NAMES, _SEVERITY_SOURCE_SYMBOL_ALLOWLIST)
        @test isempty(v)
    end

    violations, used = collect_src_enum_symbol_violations(ROOT, _SEVERITY_SOURCE_NAMES, _SEVERITY_SOURCE_SYMBOL_ALLOWLIST)
    for (file, line, name, snippet) in violations
        @error "SeveritySource Symbol literal outside conversion functions / allowlist" file line name snippet
    end
    @test isempty(violations)

    stale = [(f, id) for (f, id, _) in _SEVERITY_SOURCE_SYMBOL_ALLOWLIST if (f, id) ∉ used]
    @test isempty(stale) || error(
        "allowlist entries with no use in src/: $(join(["$f:$id" for (f, id) in stale], ", "))",
    )
end
