const _SRC_ROOT = joinpath(ROOT, "src")

# Module-level `const` names bound to load-time mutable containers (explicit allowlist).
const _MUTABLE_CONST_ALLOWLIST = Set(
    [
        "AUTO_PROTECTED_EXACT",
        "EXPECT_AUDIT_RULE_KEYS",
        "INTEGRITY_FORBID_RULES",
        "KNOWN_PRESET_NAMES",
        "PROJECT_RULE_KEYS",
        "PROTECTED_PATH_CHANGE_TYPES",
        "PROTECTED_PATHS_RULE_KEYS",
        "RULE_DEFS_BY_ID",
        "RULE_TABLE_KEYS",
        "SILENT_CATCH_RULE_KEYS",
        "TOP_LEVEL_CONFIG_KEYS",
        "UNSAFE_BOUNDARY_RULE_KEYS",
        "_ALLOWED_BOUNDARY_QUALIFIERS",
        "_BOUNDARY_VALUE_LEAVES",
        "_CMD_WRAPPER_CALLEES",
        "_DIFF_NAME_STATUS_PAIR",
        "_DIFF_NAME_STATUS_SINGLE",
        "_INDIRECT_EVAL_MODULES",
        "_JULIA_UNSAFE_CALLEES",
        "_RULE_ANCHOR_RX",
        "_SHELL_HAZARD_PATTERNS",
        "_UNSAFE_MACRO_SUFFIXES_CORE",
        "_UNSAFE_MACRO_SUFFIXES_STRICT",
    ],
)

const _MUTABLE_RHS_PREFIX = ("Ref{", "Ref(", "Dict", "Set{", "Set(", "IdDict", "[")

const _MODULE_LEVEL_ASSIGN_SKIP_PREFIXES = (
    "abstract type ",
    "baremodule ",
    "const ",
    "end",
    "export ",
    "function ",
    "global const ",
    "if ",
    "import ",
    "include ",
    "macro ",
    "module ",
    "mutable struct ",
    "primitive type ",
    "return ",
    "struct ",
    "using ",
    "while ",
    "for ",
    "elseif ",
    "else",
)

function _src_julia_files(dir::AbstractString)
    out = String[]
    for (root, _, files) in walkdir(dir)
        for f in files
            endswith(f, ".jl") || continue
            push!(out, joinpath(root, f))
        end
    end
    return sort(out)
end

function _is_module_level_line(line::AbstractString)
    isempty(strip(line)) && return false
    return !startswith(line, ' ') && !startswith(line, '\t')
end

function _mutable_const_rhs(s::AbstractString)
    for prefix in _MUTABLE_RHS_PREFIX
        startswith(s, prefix) && return true
    end
    return false
end

function _collect_mutable_const_bindings(text::AbstractString)
    found = String[]
    lines = split(text, '\n')
    i = 1
    while i <= length(lines)
        line = lines[i]
        _is_module_level_line(line) || (i += 1; continue)
        s = strip(line)
        if !startswith(s, "const ")
            i += 1
            continue
        end
        m = match(r"^const\s+([A-Za-z_][A-Za-z0-9_.]*)\s*=", s)
        m === nothing && (i += 1; continue)
        eq = findfirst('=', s)
        rhs = eq === nothing ? "" : strip(s[(eq + 1):end])
        if isempty(rhs) || rhs == "Set" || rhs == "Dict" || rhs == "IdDict"
            j = i + 1
            while j <= length(lines)
                rhs2 = strip(lines[j])
                if _mutable_const_rhs(rhs2) || startswith(rhs2, "Set(") || startswith(rhs2, "Dict(")
                    push!(found, m.captures[1])
                    break
                end
                _is_module_level_line(lines[j]) && break
                j += 1
            end
        elseif _mutable_const_rhs(rhs)
            push!(found, m.captures[1])
        end
        i += 1
    end
    return found
end

function _module_level_binding_line(line::AbstractString)
    s = strip(line)
    isempty(s) && return false
    startswith(s, '#') && return false
    for prefix in _MODULE_LEVEL_ASSIGN_SKIP_PREFIXES
        startswith(s, prefix) && return false
    end
    return occursin(r"^[A-Za-z_@][A-Za-z0-9_.]*\s*=", s)
end

function _collect_module_level_bindings(text::AbstractString)
    found = String[]
    for line in split(text, '\n')
        _is_module_level_line(line) || continue
        _module_level_binding_line(line) || continue
        push!(found, strip(line))
    end
    return found
end

const _RUNTIME_BRACKET_ASSIGN = Regex(
    "\\b([_A-Za-z][A-Za-z0-9_.]*)\\[\\]\\s*=",
)
const _RUNTIME_INDEX_ASSIGN = Regex(
    "\\b([_A-Za-z][A-Za-z0-9_.]*)\\[[^\\]]+\\]\\s*=",
)
const _RUNTIME_MUTATING_CALL = Regex(
    "\\b(?:empty!|push!|pop!|delete!|setindex!|merge!|append!)\\(\\s*([_A-Za-z][A-Za-z0-9_.]*)\\b",
)

function _runtime_mutations_in_text(text::AbstractString)
    hits = Tuple{String, String, SubString{String}}[]
    for (rx, kind) in (
            (_RUNTIME_BRACKET_ASSIGN, "[]="),
            (_RUNTIME_INDEX_ASSIGN, "[...]="),
            (_RUNTIME_MUTATING_CALL, "mutating call"),
        )
        for m in eachmatch(rx, text)
            push!(hits, (kind, m.captures[1], m.match))
        end
    end
    return hits
end

@testset "no mutable linter globals (src/)" begin
    all_mutable = String[]
    for path in _src_julia_files(_SRC_ROOT)
        text = read(path, String)
        rel = relpath(path, ROOT)
        bindings = _collect_module_level_bindings(text)
        @test isempty(bindings) || error(
            "$rel: non-const module-level binding(s):\n$(join(bindings, '\n'))",
        )
        for name in _collect_mutable_const_bindings(text)
            push!(all_mutable, name)
            name in _MUTABLE_CONST_ALLOWLIST ||
                error("$rel: mutable const `$name` is not in the allowlist")
        end
        file_mutable = Set(_collect_mutable_const_bindings(text))
        for (kind, id, snippet) in _runtime_mutations_in_text(text)
            if kind == "[]="
                id in file_mutable || id in _MUTABLE_CONST_ALLOWLIST ||
                    continue
            else
                id in _MUTABLE_CONST_ALLOWLIST || continue
            end
            error("$rel: runtime mutation on `$id` ($kind): $(strip(snippet))")
        end
    end
    allow_unused = setdiff(_MUTABLE_CONST_ALLOWLIST, Set(all_mutable))
    @test isempty(allow_unused) || error(
        "allowlist name(s) with no binding in src/: $(join(sort(collect(allow_unused)), ", "))",
    )
end
