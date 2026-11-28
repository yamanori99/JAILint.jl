using AgentRuleLint
using JSON
using JSONSchema
using Test

const SCHEMA_PATH = joinpath(ROOT, "schemas", "check-jsonl.schema.json")
const OUTPUT_GOLDEN_DIR = joinpath(ROOT, "test", "goldens", "output")

function _line_validator_schema(full::Dict{String, Any})
    return Schema(
        Dict(
            "\$defs" => full["\$defs"],
            "oneOf" => full["items"]["oneOf"],
        ),
    )
end

function _validate_jsonl!(text::AbstractString, validator::Schema)
    lines = split(strip(text), '\n')
    length(lines) >= 2 || error("expected header, diagnostics, and summary lines")
    kinds = String[]
    for (i, line) in enumerate(lines)
        obj = JSON.parse(line; dicttype = Dict{String, Any})
        err = validate(validator, obj)
        err === nothing || error("schema validation failed at line $i: $err")
        t = String(obj["type"])
        push!(kinds, t)
        roundtrip = JSON.json(obj)
        line == roundtrip || error("JSON round-trip mismatch at line $i")
    end
    @test kinds[1] == "header"
    @test kinds[end] == "summary"
    return nothing
end

function _collect_jsonl_outputs()
    outs = String[]
    for sub in ("", "no_config", "minimal_config")
        dir = sub == "" ? OUTPUT_GOLDEN_DIR : joinpath(OUTPUT_GOLDEN_DIR, sub)
        push!(outs, read(joinpath(dir, "check_json.txt"), String))
    end
    res = AgentRuleLint.check(ROOT; paths = [joinpath("test", "corpus")])
    push!(outs, AgentRuleLint.format_json(res))
    res_git = AgentRuleLint.check(
        ROOT;
        paths = [joinpath("test", "corpus", "split_string.jl")],
        config_from = "HEAD",
    )
    push!(outs, AgentRuleLint.format_json(res_git))
    return outs
end

function _property_paths_from_defs(defs::Dict{String, Any}, prefix::String = "")
    paths = Set{String}()
    for (def_name, def) in defs
        props = get(def, "properties", nothing)
        props === nothing && continue
        for (key, val) in props
            path = isempty(prefix) ? "$def_name.$key" : "$prefix.$key"
            push!(paths, path)
            nested = get(val, "properties", nothing)
            nested isa Dict || continue
            for nk in keys(nested)
                push!(paths, "$path.$nk")
            end
        end
    end
    return paths
end

function _observed_property_paths(text::AbstractString)
    seen = Set{String}()
    for line in split(strip(text), '\n'; keepempty = false)
        obj = JSON.parse(line; dicttype = Dict{String, Any})
        t = String(obj["type"])
        for (k, v) in obj
            push!(seen, "$t.$k")
            if v isa Dict{String, Any}
                for nk in keys(v)
                    push!(seen, "$t.$k.$nk")
                end
            end
        end
    end
    return seen
end

function _schema_property_keys(defs::Dict{String, Any}, def_name::String)
    def = defs[def_name]
    return sort(collect(String.(keys(def["properties"]))))
end

@testset "output schema (#105 PR2)" begin
    @testset "regenerated schema matches committed file" begin
        want = AgentRuleLint.schema_json_text(AgentRuleLint.output_schema())
        got = read(SCHEMA_PATH, String)
        @test want == got
    end

    @testset "record fields match schema properties" begin
        full = JSON.parse(read(SCHEMA_PATH, String); dicttype = Dict{String, Any})
        defs = full["\$defs"]
        for (def_name, rt) in (
                ("header", AgentRuleLint.HeaderRecord),
                ("diagnostic", AgentRuleLint.DiagnosticRecord),
                ("summary", AgentRuleLint.SummaryRecord),
            )
            @test _schema_property_keys(defs, def_name) == sort(collect(String.(fieldnames(rt))))
        end
        hdr_props = defs["header"]["properties"]["config_source"]["properties"]
        @test sort(collect(keys(hdr_props))) ==
            sort(collect(String.(fieldnames(AgentRuleLint.ConfigSourceRecord))))
        span_props = defs["diagnostic"]["properties"]["span"]["properties"]
        @test sort(collect(keys(span_props))) ==
            sort(collect(String.(fieldnames(AgentRuleLint.SpanRecord))))
    end

    full = JSON.parse(read(SCHEMA_PATH, String); dicttype = Dict{String, Any})
    validator = _line_validator_schema(full)

    @testset "corpus JSONL validates against schema" begin
        for text in _collect_jsonl_outputs()
            _validate_jsonl!(text, validator)
        end
    end

    @testset "every schema property appears in corpus output" begin
        required = _property_paths_from_defs(full["\$defs"])
        observed = Set{String}()
        for text in _collect_jsonl_outputs()
            union!(observed, _observed_property_paths(text))
        end
        for path in required
            @test path in observed
        end
    end

    @testset "JSON escapes control characters and round-trips" begin
        msg = string(Char(0x1F)) * "quote\"back\\\\slash" * "café"
        path = "cfg" * string(Char(0x1B)) * "/weird\"path.toml"
        cs = AgentRuleLint.ConfigSource(AgentRuleLint.ConfigSourceKind.PATH, path, "", "")
        d = AgentRuleLint.Violation(
            "project/no-internal-codename",
            AgentRuleLint.Origin.PROJECT,
            AgentRuleLint.Level.DENY,
            "x.jl",
            AgentRuleLint.Span(1, 1, 1, 5),
            1,
            "v1:" * repeat('a', 40),
            AgentRuleLint.ExpectStatus.NONE,
            false,
            msg,
            "",
            "",
        )
        res = AgentRuleLint.CheckResult([d], true, 1, cs, AgentRuleLint.OutputFormat.JSON, 20, 0, 1)
        js = AgentRuleLint.format_json(res)
        _validate_jsonl!(js, validator)
        hdr = JSON.parse(first(split(strip(js), '\n')); dicttype = Dict{String, Any})
        @test hdr["config_source"]["path"] == path
        diag_line = only(
            l for l in split(strip(js), '\n'; keepempty = false) if
                JSON.parse(l; dicttype = Dict{String, Any})["type"] == "diagnostic"
        )
        diag = JSON.parse(diag_line; dicttype = Dict{String, Any})
        @test diag["message"] == msg
    end
end
