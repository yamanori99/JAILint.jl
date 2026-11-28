using AgentRuleLint
using JSON
using JSONSchema
using JSON: StructUtils
using Test

function _wire_names(::Type{T}) where {T}
    return collect(String, AgentRuleLint.wire_name.(instances(T)))
end

function _json_type_name(@nospecialize(typ::Type))
    typ === Bool && return "boolean"
    typ <: Integer && return "integer"
    typ <: AbstractString && return "string"
    typ <: AgentRuleLint.Origin.T && return "string"
    typ <: AgentRuleLint.Level.T && return "string"
    typ <: AgentRuleLint.ExpectStatus.T && return "string"
    typ === AgentRuleLint.SpanRecord && return "object"
    return "unknown"
end

function _expected_diagnostic_properties()
    props = Dict{String, Any}()
    for (name, typ) in zip(
            fieldnames(AgentRuleLint.DiagnosticRecord),
            fieldtypes(AgentRuleLint.DiagnosticRecord),
        )
        key = String(name)
        entry = Dict{String, Any}("type" => _json_type_name(typ))
        if typ <: AgentRuleLint.Origin.T
            entry["enum"] = _wire_names(AgentRuleLint.Origin.T)
        elseif typ <: AgentRuleLint.Level.T
            entry["enum"] = _wire_names(AgentRuleLint.Level.T)
        elseif typ <: AgentRuleLint.ExpectStatus.T
            entry["enum"] = _wire_names(AgentRuleLint.ExpectStatus.T)
        elseif typ === AgentRuleLint.SpanRecord
            sub = Dict{String, Any}()
            for (sname, styp) in zip(fieldnames(AgentRuleLint.SpanRecord), fieldtypes(AgentRuleLint.SpanRecord))
                sub[String(sname)] = Dict{String, Any}("type" => _json_type_name(styp))
            end
            entry["properties"] = sub
        end
        props[key] = entry
    end
    return props
end

@testset "JSONSchema generator spike (#105 PR1)" begin
    @testset "generated draft and property keys" begin
        sch = JSONSchema.schema(AgentRuleLint.DiagnosticRecord)
        data = sch.data
        @test data["\$schema"] == "https://json-schema.org/draft-07/schema#"
        gen_props = get(data, "properties", Dict{String, Any}())
        expected_keys = String.(fieldnames(AgentRuleLint.DiagnosticRecord))
        @test sort(collect(keys(gen_props))) == sort(collect(expected_keys))
    end

    @testset "hand-checked expectation vs JSONSchema.jl (enums and nested span)" begin
        expected = _expected_diagnostic_properties()
        sch = JSONSchema.schema(AgentRuleLint.DiagnosticRecord)
        gen_props = sch.data["properties"]
        for key in String.(fieldnames(AgentRuleLint.DiagnosticRecord))
            gen_entry = gen_props[key]
            exp_entry = expected[key]
            if haskey(exp_entry, "enum")
                @test !haskey(gen_entry, "enum")
                @test get(gen_entry, "type", nothing) !== exp_entry["type"]
            else
                @test get(gen_entry, "type", nothing) == exp_entry["type"]
            end
            if haskey(exp_entry, "properties")
                gen_span = get(gen_props["span"], "properties", Dict{String, Any}())
                @test sort(collect(keys(gen_span))) ==
                    sort(collect(String.(fieldnames(AgentRuleLint.SpanRecord))))
            end
        end
    end

    @testset "Union{Nothing,String} mapping" begin
        u = JSONSchema.schema(Union{Nothing, String})
        @test u.data["type"] == ["string", "null"]
    end

    @testset "StructUtils field tags are not consumed by JSONSchema.jl" begin
        @tags struct _TagProbe
            t::String & (
                jsonschema = (
                    description = "probe",
                    pattern = "^v1:",
                    enum = ("a", "b"),
                ),
            )
        end
        props = JSONSchema.schema(_TagProbe).data["properties"]
        probe = props["t"]
        @test get(probe, "const", nothing) === nothing
        @test get(probe, "description", nothing) === nothing
        @test get(probe, "pattern", nothing) === nothing
        @test get(probe, "enum", nothing) === nothing
    end
end
