using JSON: JSON

const CHECK_JSONL_SCHEMA_ID =
    "https://github.com/yamanori99/AgentRuleLint.jl/schemas/check-jsonl.schema.json"
const JSON_SCHEMA_DRAFT = "https://json-schema.org/draft/2020-12/schema"

schema_overrides(::Type) = Dict{Symbol, Dict{String, Any}}()

function schema_overrides(::Type{HeaderRecord})
    return Dict(
        :type => Dict{String, Any}("const" => "header"),
        :position_encoding => Dict{String, Any}("const" => "utf8-codepoint-1based"),
        :parser => Dict{String, Any}("description" => "Unstable in 0.1.0."),
    )
end

function schema_overrides(::Type{DiagnosticRecord})
    return Dict(
        :type => Dict{String, Any}("const" => "diagnostic"),
        :fingerprint => Dict{String, Any}("pattern" => raw"^v1:[0-9a-f]{40}$"),
        :message => Dict{String, Any}("description" => "Unstable in 0.1.0."),
    )
end

function schema_overrides(::Type{SummaryRecord})
    return Dict(
        :type => Dict{String, Any}("const" => "summary"),
        :exit_code => Dict{String, Any}("minimum" => 0, "maximum" => 3),
    )
end

function _enum_wire_names(@nospecialize(T::Type))
    return sort(collect(String, wire_name.(instances(T))))
end

function _schema_enum(@nospecialize(T::Type))
    return Dict{String, Any}("type" => "string", "enum" => _enum_wire_names(T))
end

function _field_type_schema(@nospecialize(typ::Type))
    typ === Bool && return Dict{String, Any}("type" => "boolean")
    typ <: Integer && return Dict{String, Any}("type" => "integer")
    typ <: AbstractString && return Dict{String, Any}("type" => "string")
    typ <: Origin.T && return _schema_enum(Origin.T)
    typ <: Level.T && return _schema_enum(Level.T)
    typ <: ExpectStatus.T && return _schema_enum(ExpectStatus.T)
    typ <: ConfigSourceKind.T && return _schema_enum(ConfigSourceKind.T)
    typ <: SeveritySource.T && return _schema_enum(SeveritySource.T)
    typ isa Union && _is_optional_union(typ) && return _field_type_schema(optional_union_some(typ))
    _is_record_struct(typ) && return _record_object_schema(typ)
    throw(InternalError("no JSON schema mapping for field type $typ"))
end

function _is_record_struct(@nospecialize(typ::Type))
    return typ === SpanRecord || typ === ConfigSourceRecord || typ === HeaderRecord ||
        typ === DiagnosticRecord || typ === SummaryRecord
end

function _is_optional_union(@nospecialize(typ::Type))
    typ isa Union || return false
    return Nothing in Base.uniontypes(typ)
end

function optional_union_some(@nospecialize(typ::Type))
    others = filter(!=(Nothing), Base.uniontypes(typ))
    length(others) == 1 || throw(InternalError("unsupported Union for schema: $typ"))
    return only(others)
end

function _field_schema_required(@nospecialize(typ::Type))
    return !_is_optional_union(typ)
end

function _record_object_schema(@nospecialize(T::Type))
    props = Dict{String, Any}()
    required = String[]
    overrides = schema_overrides(T)
    for (name, typ) in zip(fieldnames(T), fieldtypes(T))
        key = string(name)
        prop = _field_type_schema(typ)
        if haskey(overrides, name)
            prop = merge(prop, overrides[name])
        end
        props[key] = prop
        _field_schema_required(typ) && push!(required, key)
    end
    sort!(required)
    return Dict{String, Any}(
        "type" => "object",
        "required" => required,
        "properties" => props,
        "additionalProperties" => false,
    )
end

function output_schema()
    ver = string(AGENTRULELINT_VERSION)
    header = _record_object_schema(HeaderRecord)
    diagnostic = _record_object_schema(DiagnosticRecord)
    summary = _record_object_schema(SummaryRecord)
    return Dict{String, Any}(
        "\$schema" => JSON_SCHEMA_DRAFT,
        "\$id" => CHECK_JSONL_SCHEMA_ID,
        "title" => "AgentRuleLint check JSONL",
        "description" =>
            "One JSON object per line from \`agentrulelint check --format=json\`. Fields marked unstable may change in $ver without a major bump.",
        "type" => "array",
        "items" => Dict{String, Any}(
            "oneOf" => [
                Dict{String, Any}("\$ref" => "#/\$defs/header"),
                Dict{String, Any}("\$ref" => "#/\$defs/diagnostic"),
                Dict{String, Any}("\$ref" => "#/\$defs/summary"),
            ],
        ),
        "\$defs" => Dict{String, Any}(
            "header" => header,
            "diagnostic" => diagnostic,
            "summary" => summary,
        ),
    )
end

function _sort_json_keys(x)
    if x isa Dict
        return Dict{String, Any}(k => _sort_json_keys(x[k]) for k in sort(collect(keys(x)); by = String))
    elseif x isa AbstractVector
        return [_sort_json_keys(v) for v in x]
    end
    return x
end

function schema_json_text(schema::Dict{String, Any})
    text = JSON.json(_sort_json_keys(schema); pretty = 2)
    endswith(text, '\n') || (text *= '\n')
    return text
end

const SCHEMAS_DIR = normpath(joinpath(@__DIR__, "..", "schemas"))

function write_schemas()
    mkpath(SCHEMAS_DIR)
    path = joinpath(SCHEMAS_DIR, "check-jsonl.schema.json")
    write(path, schema_json_text(output_schema()))
    return nothing
end
