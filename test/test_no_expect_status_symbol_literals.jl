# Guard: `src/` must not use ExpectStatus quote literals outside conversion functions (issue #104 PR 5).

include(joinpath(@__DIR__, "enum_symbol_guard_common.jl"))
using .EnumSymbolGuard: scan_enum_symbol_source, collect_src_enum_symbol_violations

const _EXPECT_STATUS_PROBE_REL = "src/__expect_status_symbol_guard_probe__.jl"
const _EXPECT_STATUS_NAMES = Set(["none", "fulfilled", "unfulfilled", "deleted_test"])
const _EXPECT_STATUS_SYMBOL_ALLOWLIST = Tuple{String, String, String}[]

@testset "src/ ExpectStatus Symbol literal guard" begin
    @testset "syntax scan finds quote literals (probe sources)" begin
        v, _ = scan_enum_symbol_source(_EXPECT_STATUS_PROBE_REL, "x = :fulfilled\n", _EXPECT_STATUS_NAMES, _EXPECT_STATUS_SYMBOL_ALLOWLIST)
        @test any(x -> x[3] == "fulfilled", v)
        v, _ = scan_enum_symbol_source(_EXPECT_STATUS_PROBE_REL, "x == :deleted_test\n", _EXPECT_STATUS_NAMES, _EXPECT_STATUS_SYMBOL_ALLOWLIST)
        @test any(x -> x[3] == "deleted_test", v)
        v, _ = scan_enum_symbol_source(_EXPECT_STATUS_PROBE_REL, "lvl == :none\n", _EXPECT_STATUS_NAMES, _EXPECT_STATUS_SYMBOL_ALLOWLIST)
        @test any(x -> x[3] == "none", v)
        convert_fn = "function wire_name(x::ExpectStatus.T)\n    x == :none && return \"n\"\n    return \"\"\nend\n"
        v, _ = scan_enum_symbol_source(_EXPECT_STATUS_PROBE_REL, convert_fn, _EXPECT_STATUS_NAMES, _EXPECT_STATUS_SYMBOL_ALLOWLIST)
        @test isempty(v)
    end

    violations, used = collect_src_enum_symbol_violations(ROOT, _EXPECT_STATUS_NAMES, _EXPECT_STATUS_SYMBOL_ALLOWLIST)
    for (file, line, name, snippet) in violations
        @error "ExpectStatus Symbol literal outside conversion functions / allowlist" file line name snippet
    end
    @test isempty(violations)

    stale = [(f, id) for (f, id, _) in _EXPECT_STATUS_SYMBOL_ALLOWLIST if (f, id) ∉ used]
    @test isempty(stale) || error(
        "allowlist entries with no use in src/: $(join(["$f:$id" for (f, id) in stale], ", "))",
    )
end
