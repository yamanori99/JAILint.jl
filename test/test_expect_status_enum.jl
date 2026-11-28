module ExpectStatusMisspellProbe
    using AgentRuleLint
    probe() = getproperty(AgentRuleLint.ExpectStatus, :FULFILED)
end

@testset "ExpectStatus enum" begin
    @testset "misspelled member raises UndefVarError in a test module" begin
        err = @test_throws UndefVarError ExpectStatusMisspellProbe.probe()
        @test err.value isa UndefVarError
    end

    @testset "wire_name spellings match JSON expect_status field" begin
        @test collect(AgentRuleLint.wire_name.(instances(AgentRuleLint.ExpectStatus.T))) ==
            ["none", "fulfilled", "unfulfilled", "deleted_test"]
        for x in instances(AgentRuleLint.ExpectStatus.T)
            @test AgentRuleLint.wire_name(x) == lowercase(String(Symbol(x)))
        end
    end

    @testset "wire_name labels are distinct per member" begin
        labels = AgentRuleLint.wire_name.(instances(AgentRuleLint.ExpectStatus.T))
        @test length(unique(labels)) == length(labels)
    end
end
