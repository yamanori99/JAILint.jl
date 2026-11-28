@testset "config-from" begin
    pol = AgentRuleLint.resolve_policy(ROOT; config_from = "HEAD")
    @test pol.config_source.kind == AgentRuleLint.ConfigSourceKind.GIT_REF
    @test_throws AgentRuleLint.GitError AgentRuleLint.resolve_policy(ROOT; config_from = "not-a-ref-zzz")
end
