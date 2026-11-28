# Fingerprint v1 payload excludes expect_status (recorded on origin/main before #104 PR 5).
const _EXPECT_STATUS_FP_PROBE = "v1:b08a4cfc2b82f840aca13deb2ba5849704212661"

const _EXPECT_FP_SRC = "x = 1\n"
const _EXPECT_FP_PATH = "test/corpus/fp_expect_status_probe.jl"

function _fp_for_expect_status(status::AgentRuleLint.ExpectStatus.T)
    d = AgentRuleLint.Violation(
        "agentrulelint/fp-probe",
        AgentRuleLint.Origin.AGENTRULELINT,
        AgentRuleLint.Level.WARN,
        _EXPECT_FP_PATH,
        AgentRuleLint.Span(1, 1, 1, 3),
        1,
        "",
        status,
        false,
        "probe message",
        "",
        "",
    )
    diags = AgentRuleLint.Violation[d]
    sources = Dict(_EXPECT_FP_PATH => _EXPECT_FP_SRC)
    AgentRuleLint.assign_diagnostic_fingerprints!(diags, sources)
    return diags[1].fingerprint
end

@testset "expect_status does not affect diagnostic fingerprint v1" begin
    for x in instances(AgentRuleLint.ExpectStatus.T)
        @test _fp_for_expect_status(x) == _EXPECT_STATUS_FP_PROBE
    end
end
