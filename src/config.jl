using TOML

const CONFIG_FILENAME = ".AgentRuleLint.jl.toml"
const LEGACY_CONFIG_FILENAME = ".AgentRuleLintConfig.toml"
const CONFIG_FILE_HEADER =
    "# AgentRuleLint.jl — https://github.com/yamanori99/AgentRuleLint.jl\n"
const CEILINGS_REL = ".agentrulelint/ceilings.toml"

function legacy_config_rename_error()::ConfigError
    return ConfigError(
        "found $LEGACY_CONFIG_FILENAME; rename to $CONFIG_FILENAME with: git mv $LEGACY_CONFIG_FILENAME $CONFIG_FILENAME",
    )
end

function reject_legacy_config_file!(root::AbstractString)
    root = abspath(String(root))
    isfile(joinpath(root, LEGACY_CONFIG_FILENAME)) && throw(legacy_config_rename_error())
    return nothing
end

function reject_legacy_config_at_ref!(root::AbstractString, commit_sha::AbstractString)
    git_tree_path_exists(root, commit_sha, LEGACY_CONFIG_FILENAME) &&
        throw(legacy_config_rename_error())
    return nothing
end

function render_init_config()::String
    ver = AGENTRULELINT_VERSION
    return string(
        CONFIG_FILE_HEADER,
        """
        agentrulelint_version = \"=$(ver)\"

        [rules.protected-paths]
        level = \"forbid\"
        """,
    )
end

const TOP_LEVEL_CONFIG_KEYS = Set(
    [
        "agentrulelint_version",
        "default_format",
        "exit_severity",
        "max_hits_per_rule",
        "presets",
        "project_rules",
    ]
)
const RULE_TABLE_KEYS = Set(["level", "intent", "do_not"])
const EXPECT_AUDIT_RULE_KEYS = Set(["level", "intent", "do_not", "on_allow_rule"])
const SILENT_CATCH_RULE_KEYS = Set(["level", "intent", "do_not", "warn_counts_as_handling"])
const UNSAFE_BOUNDARY_RULE_KEYS = Set(["level", "intent", "do_not", "allow_modules", "allow_globs"])
const PROTECTED_PATHS_RULE_KEYS =
    Set(["level", "intent", "do_not", "project_toml_policy", "paths"])
const PROTECTED_PATH_CHANGE_TYPES = Set(["added", "modified", "deleted", "renamed", "copied"])
const PROTECTED_PATHS_RULE = "protected-paths"
const CEILING_RATCHET_RULE = "ceiling-ratchet"
const SCOPE_PATHS_RULE = "scope-paths"
const ANALYSIS_INCOMPLETE_RULE = "analysis-incomplete"
const INTEGRITY_FORBID_RULES = Set(
    [
        ANALYSIS_INCOMPLETE_RULE,
        PROTECTED_PATHS_RULE,
        CEILING_RATCHET_RULE,
        SCOPE_PATHS_RULE,
    ]
)
const DEFAULT_PROJECT_TOML_POLICY = "semantic"
const PROJECT_RULE_KEYS = Set(
    [
        "id",
        "level",
        "paths",
        "forbid_literals",
        "intent",
        "do_not",
    ]
)
const KNOWN_PRESET_NAMES = Set(["shell-safety", "unsafe-boundary/strict"])
const SHELL_SAFETY_PRESET_ID = "shell-safety/process-pattern"
const UNSAFE_BOUNDARY_STRICT_PRESET_ID = "unsafe-boundary/strict"

function _reject_unknown_keys!(dict::Dict, allowed::Set{String}, label::String)
    for k in keys(dict)
        String(k) in allowed || throw(ConfigError("unknown key '$k' in $label"))
    end
    return nothing
end

function _parse_rule_level(raw, label::String)
    s = raw isa AbstractString ? strip(raw) : raw isa Symbol ? String(raw) : ""
    s == "" && throw(ConfigError("missing rule level in $label"))
    try
        return parse_enum(Level.T, s)
    catch err
        err isa ConfigError || rethrow()
        valid = join(wire_name.(instances(Level.T)), "|")
        throw(ConfigError("unknown rule level '$raw' in $label (expected $valid)"))
    end
end

function _parse_warn_counts_as_handling(raw, label::String)
    raw isa Bool ||
        throw(ConfigError("expected boolean for $label (got $(typeof(raw)))"))
    return raw ? "true" : "false"
end

function _parse_on_allow_rule(raw, label::String)
    s = raw isa AbstractString ? strip(String(raw)) : ""
    try
        return parse_enum(Level.T, s)
    catch err
        err isa ConfigError || rethrow()
        valid = join(wire_name.(instances(Level.T)), "|")
        throw(
            ConfigError(
                "unknown on_allow_rule '$raw' in $label (expected $valid)",
            ),
        )
    end
end

function _parse_default_format(raw, label::String)
    s = raw isa AbstractString ? strip(String(raw)) : ""
    try
        return parse_enum(OutputFormat.T, s)
    catch err
        err isa ConfigError || rethrow()
        valid = join(wire_name.(instances(OutputFormat.T)), "|")
        throw(ConfigError("unknown default_format '$raw' in $label (expected $valid)"))
    end
end

function _parse_preset_list(raw, label::String)
    raw isa AbstractVector || throw(ConfigError("$label must be an array"))
    out = String[]
    for (i, p) in enumerate(raw)
        p isa AbstractString || throw(ConfigError("$label[$i] must be a string"))
        name = String(p)
        name in KNOWN_PRESET_NAMES ||
            throw(ConfigError("unknown preset '$name' in $label"))
        push!(out, name)
    end
    return out
end

_rule_level(s::AbstractString) = _parse_rule_level(s, "rule level")
_rule_level(s::Symbol) = _parse_rule_level(String(s), "rule level")

function _require_string(dict, key, path)
    haskey(dict, key) || throw(ConfigError("missing key '$key' in $path"))
    v = dict[key]
    v isa AbstractString || throw(ConfigError("expected string for '$key' in $path"))
    return String(v)
end

function _opt_string(dict, key, default = "")
    !haskey(dict, key) && return default
    v = dict[key]
    v isa AbstractString || throw(ConfigError("expected string for '$key'"))
    return String(v)
end

function _parse_version_pin(raw::AbstractString)
    s = strip(raw)
    startswith(s, "=") && return VersionNumber(s[2:end])
    return VersionNumber(s)
end

function validate_agentrulelint_version!(toml_version::VersionNumber, pkg::VersionNumber)
    pkg_major, pkg_minor = pkg.major, pkg.minor
    return if toml_version.major != pkg_major || toml_version.minor != pkg_minor
        throw(
            ConfigError(
                "agentrulelint_version pin $(toml_version) does not match AgentRuleLint $(pkg)",
            ),
        )
    end
end

function load_toml_string(toml_string::String, path_label::String)
    try
        return TOML.parse(toml_string)
    catch err
        err isa InterruptException && rethrow()
        throw(ParseError("TOML parse error in $path_label: $(format_error(err))"))
    end
end

function load_toml_file(path::String)
    isfile(path) || throw(ConfigError("config not found: $path"))
    try
        return TOML.parsefile(path)
    catch err
        err isa InterruptException && rethrow()
        throw(ParseError("TOML parse error in $path: $(format_error(err))"))
    end
end

function _collect_rule_tables(raw::Dict)
    out = Tuple{String, Dict}[]
    seen = Set{String}()
    if haskey(raw, "rules")
        box = raw["rules"]
        box isa Dict || throw(ConfigError("rules must be a table"))
        for (id, content) in box
            sid = String(id)
            sid in seen && throw(ConfigError("duplicate rules.$sid"))
            push!(seen, sid)
            content isa Dict || throw(ConfigError("rules.$sid must be a table"))
            push!(out, (sid, content))
        end
    end
    for (section, content) in raw
        startswith(section, "rules.") || continue
        id = section[7:end]
        id in seen && throw(ConfigError("duplicate rules.$id"))
        push!(seen, id)
        content isa Dict || throw(ConfigError("$section must be a table"))
        push!(out, (id, content))
    end
    return out
end

function _validate_shell_safety_preset!(presets::Vector{String}, rules::Dict{String, RuleSpec})
    haskey(rules, SHELL_SAFETY_PRESET_ID) || return
    "shell-safety" in presets && return
    throw(
        ConfigError(
            "rules.$SHELL_SAFETY_PRESET_ID requires presets = [\"shell-safety\"] (preset table without active preset)",
        ),
    )
end

function _validate_unsafe_boundary_strict_preset!(presets::Vector{String}, rules::Dict{String, RuleSpec})
    haskey(rules, UNSAFE_BOUNDARY_STRICT_PRESET_ID) || return
    UNSAFE_BOUNDARY_STRICT_PRESET_ID in presets && return
    throw(
        ConfigError(
            "rules.$UNSAFE_BOUNDARY_STRICT_PRESET_ID requires presets = [\"unsafe-boundary/strict\"] (preset table without active preset)",
        ),
    )
end

function _load_shell_safety_config(presets::Vector{String}, rules::Dict{String, RuleSpec})
    active = "shell-safety" in presets
    !active && return ShellSafetyConfig()
    spec = get(rules, SHELL_SAFETY_PRESET_ID, nothing)
    level = spec === nothing ? Level.DENY : spec.level
    intent = spec === nothing ? "" : spec.intent
    do_not = spec === nothing ? "" : spec.do_not
    return ShellSafetyConfig(true, level, intent, do_not)
end

function _load_unsafe_boundary_strict_config(presets::Vector{String}, rules::Dict{String, RuleSpec})
    active = UNSAFE_BOUNDARY_STRICT_PRESET_ID in presets
    !active && return UnsafeBoundaryStrictConfig()
    spec = get(rules, UNSAFE_BOUNDARY_STRICT_PRESET_ID, nothing)
    level = spec === nothing ? Level.WARN : spec.level
    intent = spec === nothing ? "" : spec.intent
    do_not = spec === nothing ? "" : spec.do_not
    return UnsafeBoundaryStrictConfig(true, level, intent, do_not)
end

function _parse_string_array(raw, label::AbstractString)
    raw isa AbstractVector || throw(ConfigError("$label must be an array"))
    out = String[]
    for (i, v) in enumerate(raw)
        v isa AbstractString || throw(ConfigError("$label[$i] must be a string"))
        push!(out, String(v))
    end
    return out
end

function _parse_protected_path_on(raw, sub::AbstractString)
    raw === nothing && return nothing
    raw isa AbstractVector || throw(ConfigError("$sub.on must be an array"))
    isempty(raw) && throw(ConfigError("$sub.on must not be empty"))
    out = Set{String}()
    for (k, v) in enumerate(raw)
        on_label = "$sub.on[$k]"
        v isa AbstractString || throw(ConfigError("$on_label must be a string"))
        s = String(v)
        s in PROTECTED_PATH_CHANGE_TYPES ||
            throw(ConfigError("unknown protected-paths change type '$s' in $on_label"))
        s in out && throw(ConfigError("duplicate change type '$s' in $sub.on"))
        push!(out, s)
    end
    return out
end

function _parse_protected_paths_globs(content::Dict, label::String)
    raw = get(content, "paths", [])
    raw isa AbstractVector || throw(ConfigError("$label.paths must be an array"))
    out = ProtectedGlobEntry[]
    for (j, entry) in enumerate(raw)
        sub = "rules.$label.paths[$j]"
        entry isa Dict || throw(ConfigError("$sub must be a table"))
        _reject_unknown_keys!(entry, Set(["glob", "reason", "on"]), sub)
        glob = _require_string(entry, "glob", sub)
        reason = _require_string(entry, "reason", sub)
        rx = compile_path_glob(glob, sub)
        change_types = _parse_protected_path_on(get(entry, "on", nothing), sub)
        push!(out, ProtectedGlobEntry(rx, reason, change_types))
    end
    return out
end

function _load_unsafe_boundary_config(raw::Dict, rules::Dict{String, RuleSpec})
    spec = get(rules, "unsafe-boundary", nothing)
    spec === nothing && return UnsafeBoundaryConfig()
    allow_modules = String[]
    allow_globs = Regex[]
    for (id, content) in _collect_rule_tables(raw)
        id == "unsafe-boundary" || continue
        if haskey(content, "allow_modules")
            allow_modules = _parse_string_array(content["allow_modules"], "rules.unsafe-boundary.allow_modules")
        end
        if haskey(content, "allow_globs")
            globs = _parse_string_array(content["allow_globs"], "rules.unsafe-boundary.allow_globs")
            for (j, g) in enumerate(globs)
                push!(allow_globs, compile_path_glob(g, "rules.unsafe-boundary.allow_globs[$j]"))
            end
        end
        break
    end
    return UnsafeBoundaryConfig(
        true,
        spec.level,
        allow_modules,
        allow_globs,
        spec.intent,
        spec.do_not,
    )
end

function _parse_project_toml_policy(raw, label::String)
    s = strip(raw isa AbstractString ? String(raw) : "")
    s == DEFAULT_PROJECT_TOML_POLICY && return DEFAULT_PROJECT_TOML_POLICY
    throw(ConfigError("unknown project_toml_policy '$raw' in $label (expected semantic)"))
end

function _load_rules_table(raw::Dict)
    rules = Dict{String, RuleSpec}()
    for (id, content) in _collect_rule_tables(raw)
        id in (SHELL_SAFETY_PRESET_ID, UNSAFE_BOUNDARY_STRICT_PRESET_ID) ||
            validate_kebab_rule_id(id, "rules.$id")
        allowed = if id == "expect-audit"
            EXPECT_AUDIT_RULE_KEYS
        elseif id == "silent-catch"
            SILENT_CATCH_RULE_KEYS
        elseif id == "unsafe-boundary"
            UNSAFE_BOUNDARY_RULE_KEYS
        elseif id == PROTECTED_PATHS_RULE
            PROTECTED_PATHS_RULE_KEYS
        else
            RULE_TABLE_KEYS
        end
        _reject_unknown_keys!(content, allowed, "rules.$id")
        level = haskey(content, "level") ?
            _parse_rule_level(content["level"], "rules.$id.level") : Level.DENY
        if id in INTEGRITY_FORBID_RULES && level != Level.FORBID
            throw(
                ConfigError(
                    "rules.$id.level must be forbid (integrity rules cannot be weakened)",
                ),
            )
        end
        intent = _opt_string(content, "intent")
        do_not = _opt_string(content, "do_not")
        origin =
            id in (SHELL_SAFETY_PRESET_ID, UNSAFE_BOUNDARY_STRICT_PRESET_ID) ? Origin.PRESET :
            Origin.AGENTRULELINT
        extra = Dict{Symbol, String}()
        if id == "silent-catch" && haskey(content, "warn_counts_as_handling")
            extra[:warn_counts_as_handling] = _parse_warn_counts_as_handling(
                content["warn_counts_as_handling"],
                "rules.silent-catch.warn_counts_as_handling",
            )
        end
        eff_level = id in INTEGRITY_FORBID_RULES ? Level.FORBID : level
        rules[id] = fill_builtin_docs!(RuleSpec(id, origin, eff_level, intent, do_not, extra))
    end
    return rules
end

function _inject_builtin_rules!(rules::Dict{String, RuleSpec})
    if get(rules, ANALYSIS_INCOMPLETE_RULE, nothing) === nothing
        # `ANALYSIS_INCOMPLETE_RULE_DEF` is defined later in the module; resolved at call time.
        rules[ANALYSIS_INCOMPLETE_RULE] = rule_def_to_spec(ANALYSIS_INCOMPLETE_RULE_DEF)
    end
    if get(rules, PROTECTED_PATHS_RULE, nothing) === nothing
        rules[PROTECTED_PATHS_RULE] = rule_def_to_spec(PROTECTED_PATHS_RULE_DEF)
    end
    if get(rules, CEILING_RATCHET_RULE, nothing) === nothing
        rules[CEILING_RATCHET_RULE] = rule_def_to_spec(CEILING_RATCHET_RULE_DEF)
    end
    if get(rules, SCOPE_PATHS_RULE, nothing) === nothing
        rules[SCOPE_PATHS_RULE] = rule_def_to_spec(SCOPE_PATHS_RULE_DEF)
    end
    return nothing
end

function _protected_paths_config(raw::Dict, rules::Dict{String, RuleSpec})
    spec = get(rules, PROTECTED_PATHS_RULE, nothing)
    spec === nothing &&
        return DEFAULT_PROJECT_TOML_POLICY, ProtectedGlobEntry[]
    content = nothing
    for (id, c) in _collect_rule_tables(raw)
        id == PROTECTED_PATHS_RULE && (content = c; break)
    end
    content === nothing && return DEFAULT_PROJECT_TOML_POLICY, ProtectedGlobEntry[]
    pol = if haskey(content, "project_toml_policy")
        _parse_project_toml_policy(content["project_toml_policy"], "rules.$PROTECTED_PATHS_RULE")
    else
        DEFAULT_PROJECT_TOML_POLICY
    end
    globs = _parse_protected_paths_globs(content, PROTECTED_PATHS_RULE)
    return pol, globs
end

function _expect_audit_table(raw::Dict)
    for (id, content) in _collect_rule_tables(raw)
        id == "expect-audit" && return content
    end
    return nothing
end

# `paths` globs are compiled at load (see `path_glob.jl`); they select every file
# type for `forbid_literals`, not only `.jl`.
function _load_project_rules(raw::Vector)
    out = ProjectRule[]
    for (i, entry) in enumerate(raw)
        entry isa Dict || throw(ConfigError("project_rules[$i] must be a table"))
        label = "project_rules[$i]"
        _reject_unknown_keys!(entry, PROJECT_RULE_KEYS, label)
        id = validate_kebab_rule_id(_require_string(entry, "id", label), label)
        level = haskey(entry, "level") ? _parse_rule_level(entry["level"], "$label.level") : Level.DENY
        paths_raw = get(entry, "paths", String[])
        paths_raw isa AbstractVector || throw(ConfigError("$label.paths must be an array"))
        paths = String[]
        for (j, p) in enumerate(paths_raw)
            p isa AbstractString || throw(ConfigError("$label.paths[$j] must be a string"))
            push!(paths, String(p))
        end
        literals_raw = get(entry, "forbid_literals", String[])
        literals_raw isa AbstractVector || throw(ConfigError("$label.forbid_literals must be an array"))
        literals = String[]
        for (j, l) in enumerate(literals_raw)
            l isa AbstractString || throw(ConfigError("$label.forbid_literals[$j] must be a string"))
            push!(literals, String(l))
        end
        intent = _opt_string(entry, "intent")
        do_not = _opt_string(entry, "do_not")
        path_regexes = Regex[]
        for (j, p) in enumerate(paths)
            push!(path_regexes, compile_path_glob(p, "$label.paths[$j]"))
        end
        push!(out, ProjectRule(id, level, paths, path_regexes, literals, intent, do_not))
    end
    return out
end

function _reject_unknown_top_level!(raw::Dict)
    for (k, v) in raw
        sk = String(k)
        if sk in TOP_LEVEL_CONFIG_KEYS
            continue
        elseif sk == "rules"
            v isa Dict || throw(ConfigError("rules must be a table"))
            continue
        elseif startswith(sk, "rules.")
            v isa Dict || throw(ConfigError("$sk must be a table"))
            continue
        end
        throw(ConfigError("unknown config key '$sk' in $CONFIG_FILENAME"))
    end
    return nothing
end

function build_policy(raw::Dict, config_path::String, config_source::ConfigSource)
    _reject_unknown_top_level!(raw)
    ver_raw = _require_string(raw, "agentrulelint_version", CONFIG_FILENAME)
    ver = _parse_version_pin(ver_raw)
    validate_agentrulelint_version!(ver, AGENTRULELINT_VERSION)
    fmt = if haskey(raw, "default_format")
        _parse_default_format(raw["default_format"], CONFIG_FILENAME)
    else
        OutputFormat.HUMAN
    end
    max_hits = if haskey(raw, "max_hits_per_rule")
        v = raw["max_hits_per_rule"]
        v isa Integer || throw(ConfigError("max_hits_per_rule must be an integer"))
        Int(v)
    else
        20
    end
    exit_from_config = haskey(raw, "exit_severity")
    exit_sev = if exit_from_config
        _parse_exit_severity(raw["exit_severity"], CONFIG_FILENAME)
    else
        DEFAULT_EXIT_SEVERITY
    end
    exit_src = exit_from_config ? SeveritySource.CONFIG : SeveritySource.DEFAULT
    presets = if haskey(raw, "presets")
        _parse_preset_list(raw["presets"], "presets")
    else
        String[]
    end
    rules = _load_rules_table(raw)
    _inject_builtin_rules!(rules)
    _validate_shell_safety_preset!(presets, rules)
    _validate_unsafe_boundary_strict_preset!(presets, rules)
    pr_raw = get(raw, "project_rules", [])
    pr_raw isa AbstractVector || throw(ConfigError("project_rules must be an array"))
    project = _load_project_rules(pr_raw)
    on_allow = Level.WARN
    es = _expect_audit_table(raw)
    if es !== nothing && haskey(es, "on_allow_rule")
        on_allow = _parse_on_allow_rule(es["on_allow_rule"], "rules.expect-audit.on_allow_rule")
    end
    shell = _load_shell_safety_config(presets, rules)
    unsafe = _load_unsafe_boundary_config(raw, rules)
    unsafe_strict = _load_unsafe_boundary_strict_config(presets, rules)
    ptp, pglobs = _protected_paths_config(raw, rules)
    return PolicyBundle(
        ver,
        fmt,
        exit_sev,
        exit_src,
        max_hits,
        presets,
        rules,
        project,
        on_allow,
        shell,
        unsafe,
        unsafe_strict,
        config_path,
        config_source,
        ptp,
        pglobs,
    )
end

function policy_from_dict(raw::Dict, config_path::String; config_source = ConfigSource())
    return build_policy(raw, config_path, config_source)
end

function load_policy(root::AbstractString; config_path = nothing)
    root = abspath(String(root))
    cfg = something(config_path, joinpath(root, CONFIG_FILENAME))
    raw = load_toml_file(cfg)
    rel = relpath(cfg, root)
    cs = ConfigSource(ConfigSourceKind.PATH, rel, "", "")
    return policy_from_dict(raw, cfg; config_source = cs)
end

function git_resolve_commit_sha(root::AbstractString, ref::AbstractString)
    root = abspath(String(root))
    spec = string(ref, "^{commit}")
    ref_s = String(ref)
    prefix = if ref_s == "HEAD^1"
        "--config-from/--diff requires git: diff base ref not available: HEAD^1 (shallow clone or single-parent HEAD)"
    else
        "--config-from/--diff requires git: diff base ref not available: $ref_s"
    end
    try
        return strip(
            String(
                read_git_cmd(root, "rev-parse", "--verify", "--end-of-options", spec; error_prefix = prefix),
            ),
        )
    catch err
        err isa InterruptException && rethrow()
        err isa GitError && rethrow()
        throw(GitError("$prefix: $(format_error(err))"))
    end
end

function git_tree_path_exists(root::AbstractString, commit_sha::AbstractString, relpath::AbstractString)
    root = abspath(String(root))
    prefix = "--config-from/--diff requires git: failed to list $(relpath) at commit $(commit_sha)"
    try
        return !isempty(
            read_git_cmd(
                root,
                "ls-tree",
                "--name-only",
                "-z",
                "--end-of-options",
                String(commit_sha),
                "--",
                String(relpath);
                error_prefix = prefix,
            ),
        )
    catch err
        err isa InterruptException && rethrow()
        err isa GitError && rethrow()
        throw(GitError("$prefix: $(format_error(err))"))
    end
end

function git_show_blob_at_commit(root::AbstractString, commit_sha::AbstractString, relpath::AbstractString)
    root = abspath(String(root))
    showspec = string(commit_sha, ":", relpath)
    prefix = "--config-from/--diff requires git: failed to read $(relpath) at commit $(commit_sha)"
    try
        return String(
            strip(
                String(read_git_cmd(root, "show", "--end-of-options", showspec; error_prefix = prefix)),
            ),
        )
    catch err
        err isa InterruptException && rethrow()
        err isa GitError && rethrow()
        throw(GitError("$prefix: $(format_error(err))"))
    end
end

function git_show_file(ref::AbstractString, relpath::AbstractString, root::AbstractString)
    root = abspath(String(root))
    sha = git_resolve_commit_sha(root, ref)
    text = git_show_blob_at_commit(root, sha, relpath)
    return text, sha
end

function load_policy_from_ref(root::AbstractString, ref::AbstractString)
    root = abspath(String(root))
    sha = git_resolve_commit_sha(root, ref)
    reject_legacy_config_at_ref!(root, sha)
    git_tree_path_exists(root, sha, CONFIG_FILENAME) ||
        throw(ConfigError("config not found: $CONFIG_FILENAME (at $ref)"))
    cfg_text = git_show_blob_at_commit(root, sha, CONFIG_FILENAME)
    raw = load_toml_string(cfg_text, "$CONFIG_FILENAME@$ref")
    cs = ConfigSource(ConfigSourceKind.GIT_REF, CONFIG_FILENAME, String(ref), sha)
    cfg_path = joinpath(root, CONFIG_FILENAME)
    return build_policy(raw, cfg_path, cs)
end

function default_policy(root::AbstractString)
    ver = AGENTRULELINT_VERSION
    rules = Dict{String, RuleSpec}(
        ANALYSIS_INCOMPLETE_RULE => rule_def_to_spec(ANALYSIS_INCOMPLETE_RULE_DEF),
        EXPECT_AUDIT_ID => rule_def_to_spec(EXPECT_AUDIT_RULE_DEF),
        SILENT_CATCH_ID => rule_def_to_spec(SILENT_CATCH_RULE_DEF),
        CEILING_RATCHET_RULE => rule_def_to_spec(CEILING_RATCHET_RULE_DEF),
        MANIFEST_SYNC_RULE => rule_def_to_spec(MANIFEST_SYNC_RULE_DEF),
        PROTECTED_PATHS_RULE => rule_def_to_spec(PROTECTED_PATHS_RULE_DEF),
    )
    cs = ConfigSource(ConfigSourceKind.BUILTIN, "", "", "")
    cfg = joinpath(abspath(root), CONFIG_FILENAME)
    return PolicyBundle(
        ver,
        OutputFormat.HUMAN,
        DEFAULT_EXIT_SEVERITY,
        SeveritySource.DEFAULT,
        20,
        String[],
        rules,
        ProjectRule[],
        Level.WARN,
        ShellSafetyConfig(),
        UnsafeBoundaryConfig(),
        UnsafeBoundaryStrictConfig(),
        cfg,
        cs,
        DEFAULT_PROJECT_TOML_POLICY,
        ProtectedGlobEntry[],
    )
end

function resolve_policy(root::AbstractString; config_path = nothing, config_from = nothing)
    if config_from !== nothing
        return load_policy_from_ref(root, config_from)
    end
    reject_legacy_config_file!(root)
    given, cfg = resolve_user_config_path(root, config_path)
    if isfile(cfg)
        return load_policy(root; config_path = cfg)
    end
    given !== nothing &&
        throw(
        ConfigError(
            "config not found: given=$(repr(given)) normalized=$(repr(normalize_path(given)))",
        ),
    )
    return default_policy(root)
end
