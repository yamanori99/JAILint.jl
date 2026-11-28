function _unique_violations(diags::Vector{Violation})
    seen = Set{Tuple{String, Span, String, String, Bool}}()
    out = Violation[]
    for d in diags
        key = (d.path, d.span, d.rule_id, d.message, d.suppressed)
        key in seen && continue
        push!(seen, key)
        push!(out, d)
    end
    return out
end

function discover_files(
        root::AbstractString;
        paths = String[],
        diff_base = nothing,
        project_regexes = Regex[],
    )
    root = abspath(String(root))
    if !isempty(paths)
        out = String[]
        for p in paths
            p = normalize_path(p)
            ap = isabspath(p) ? p : joinpath(root, p)
            if isfile(ap)
                rel = normalize_path(relpath(ap, root))
                selected_for_lint(rel, project_regexes) || continue
                push!(out, rel)
            elseif isdir(ap)
                for (dir, _, files) in walkdir(ap)
                    for f in files
                        rel = normalize_path(relpath(joinpath(dir, f), root))
                        selected_for_lint(rel, project_regexes) || continue
                        push!(out, rel)
                    end
                end
            end
        end
        return sort(unique(out))
    end
    if diff_base !== nothing
        entries = git_diff_name_status(root, diff_base)
        out = String[]
        for (st, p) in entries
            st == 'D' && continue
            selected_for_lint(p, project_regexes) || continue
            push!(out, p)
        end
        return sort(unique(out))
    end
    out = String[]
    for (dir, _, files) in walkdir(root)
        for f in files
            rel = normalize_path(relpath(joinpath(dir, f), root))
            selected_for_lint(rel, project_regexes) || continue
            push!(out, rel)
        end
    end
    out = sort(unique(out))
    if isempty(paths) && diff_base === nothing
        filter!(p -> !startswith(p, "test/fixtures/"), out)
    end
    return out
end

# All scanned targets must be valid UTF-8 (`isvalid(String, bytes)`); invalid bytes
# fail closed before any rule runs (not via incidental JuliaSyntax errors on non-.jl).
function read_parsed_file(root::AbstractString, relpath::AbstractString)
    ap = joinpath(root, relpath)
    !isfile(ap) && throw(ParseError("file not found: $relpath"))
    bytes = read(ap)
    isvalid(String, bytes) || throw(ParseError("file is not valid UTF-8: $relpath"))
    raw = String(bytes)
    norm = normalize_source(raw)
    return ParsedFile(String(relpath), raw, norm)
end

function build_file_context(root::AbstractString, relpath::AbstractString)
    parsed = read_parsed_file(root, relpath)
    tree = if julia_source_path(relpath)
        parse_source(parsed.normalized; filename = parsed.path)
    else
        nothing
    end
    expects = if julia_source_path(relpath)
        extract_expect_lines(parsed.normalized)
    else
        extract_expect_lines_text(parsed.normalized)
    end
    return FileContext(parsed, tree, expects, Violation[])
end

function is_violation_hit(d::Violation)
    d.suppressed && return false
    d.expect_status == ExpectStatus.FULFILLED && return false
    d.level == Level.ALLOW && return false
    return true
end

function _run_check_pipeline(root::AbstractString; kwargs...)
    ensure_git_runtime!(root)
    rt = git_runtime()
    policy = resolve_policy(
        root;
        config_path = get(kwargs, :config_path, nothing),
        config_from = get(kwargs, :config_from, nothing),
    )
    paths_kw = get(kwargs, :paths, String[])
    user_paths_given = get(kwargs, :user_paths_given, String[])
    diff_base = get(kwargs, :diff_base, nothing)
    allow_paths =
        validate_allow_paths_kw(get(kwargs, :allow_paths, nothing), diff_base)
    diff_scope = diff_base === nothing ? nothing : build_diff_scope(root, diff_base)
    project_regexes = project_rule_path_regexes(policy)
    rel_files = discover_files(root; paths = paths_kw, diff_base = diff_base, project_regexes = project_regexes)
    validate_user_lint_paths!(root, user_paths_given, rel_files)

    contexts = FileContext[build_file_context(root, rel) for rel in rel_files]
    all_diags = Violation[]

    for fc in contexts
        if julia_source_path(fc.parsed.path)
            append!(all_diags, expect_audit_diagnostics(fc, policy))
        else
            append!(all_diags, expect_audit_text_diagnostics(fc, policy))
        end
        append!(all_diags, forbid_rule_suppression_attempt(fc.expects, policy, fc))
        julia_source_path(fc.parsed.path) &&
            append!(all_diags, run_silent_catch(fc, policy))
        append!(all_diags, run_project_rules(fc, policy))
        append!(all_diags, run_builtin_rules(fc, policy))
    end

    append!(
        all_diags,
        run_test_integrity(
            root,
            contexts,
            policy;
            diff_base = diff_base,
            diff_scope = diff_scope,
        ),
    )
    all_diags = dedupe_analysis_incomplete!(all_diags)

    used_by_path = Dict{String, Set{Int}}()
    for (fc, rel) in zip(contexts, rel_files)
        path_diags = Violation[]
        idxs = Int[]
        for (di, d) in enumerate(all_diags)
            d.path == rel || continue
            push!(idxs, di)
            push!(path_diags, d)
        end
        eligible = if julia_source_path(rel)
            expects_eligible_for_suppression(fc.expects, fc.parsed.normalized; tree = fc.tree)
        else
            expects_eligible_for_suppression_text(fc.expects, fc.parsed.normalized)
        end
        used = apply_expect_suppression!(path_diags, eligible, fc.parsed.normalized)
        for (j, di) in enumerate(idxs)
            all_diags[di] = path_diags[j]
        end
        used_by_path[rel] = used
    end

    for fc in contexts
        used = used_by_path[fc.parsed.path]
        append!(all_diags, unused_expect_diagnostics(fc.expects, used, fc, policy, all_diags))
    end

    append!(all_diags, run_manifest_sync(root, policy; diff_base = diff_base, paths = paths_kw))

    if diff_scope !== nothing
        path_events = git_diff_path_events(root, diff_scope.base_ref)
        all_diags = filter_diff_violations!(all_diags, diff_scope, path_events)
    end

    if diff_base !== nothing
        append!(all_diags, enforce_protected_paths(root, diff_base, policy))
    end
    if allow_paths !== nothing
        base = something(diff_base)
        events = git_diff_path_events(root, base)
        append!(all_diags, enforce_scope_paths(events, allow_paths, policy))
    end

    ceilings_path = joinpath(abspath(root), CEILINGS_REL)
    working_ceil_present = isfile(ceilings_path)
    scope_paths = if diff_scope === nothing
        nothing
    else
        Set(normalize_path(f.path) for f in diff_scope.files if f.status != 'D')
    end
    if diff_base !== nothing
        base_present, base_ceilings = load_ceilings_at_git_ref(root, diff_base, policy)
        working_ceilings = working_ceil_present ? load_ceilings(root, policy) : CeilingEntry(Dict(), Dict())
        append!(
            all_diags,
            enforce_ceilings_vs_git_base(
                working_ceilings,
                base_ceilings,
                base_present,
                working_ceil_present,
                policy,
            ),
        )
        if working_ceil_present || base_present
            viol_counts = count_violation_hits(all_diags)
            exp_counts = count_expect_lines(contexts)
            ceilings_for_counts = working_ceil_present ? working_ceilings : base_ceilings
            append!(
                all_diags,
                enforce_ceiling_ratchet(
                    viol_counts,
                    exp_counts,
                    ceilings_for_counts,
                    policy;
                    scope_paths = scope_paths,
                ),
            )
        end
    elseif working_ceil_present
        ceilings = load_ceilings(root, policy)
        viol_counts = count_violation_hits(all_diags)
        exp_counts = count_expect_lines(contexts)
        append!(
            all_diags,
            enforce_ceiling_ratchet(viol_counts, exp_counts, ceilings, policy; scope_paths = nothing),
        )
    end

    sources = Dict{String, String}(fc.parsed.path => fc.parsed.normalized for fc in contexts)
    for d in all_diags
        d.rule_id == MANIFEST_SYNC_RULE || continue
        d.path in keys(sources) && continue
        ap = joinpath(root, d.path)
        isfile(ap) || continue
        sources[d.path] = normalize_source(read(ap, String))
    end
    assign_diagnostic_fingerprints!(all_diags, sources)

    all_diags = _unique_violations(all_diags)
    all_diags = sort(all_diags; by = diag_sort_key)

    vcount = count(is_violation_hit, all_diags)
    scount = count(d -> d.suppressed, all_diags)
    threshold, thr_source, baseline, baseline_src = resolve_exit_severity(
        policy;
        exit_severity = get(kwargs, :exit_severity, nothing),
    )
    exit = check_exit_code(all_diags, threshold)
    below = Violation[
        d for d in all_diags if
            is_violation_hit(d) && !violation_counts_toward_exit(d, threshold)
    ]
    below_n = length(below)
    below_lvl, below_mixed = if below_n == 0
        nothing, false
    elseif all(d -> d.level == below[1].level, below)
        below[1].level, false
    else
        nothing, true
    end
    empty_ceilings = CeilingEntry(
        Dict{String, Dict{String, Int}}(),
        Dict{String, Dict{String, Int}}(),
    )
    display_ceilings = working_ceil_present ? load_ceilings(root, policy) : empty_ceilings
    result = CheckResult(
        all_diags,
        true,
        exit,
        policy.config_source,
        policy.default_format,
        policy.max_hits_per_rule,
        scount,
        vcount;
        ceilings = display_ceilings,
        exit_severity = threshold,
        exit_severity_source = thr_source,
        baseline_exit_severity = baseline,
        baseline_exit_severity_source = baseline_src,
        below_threshold_count = below_n,
        below_threshold_level = below_lvl,
        below_threshold_mixed = below_mixed,
        git_executable = rt.executable,
        git_version = rt.version,
    )
    return result, contexts
end

function run_check(root::AbstractString; kwargs...)
    kwargs = _normalize_check_inputs!(kwargs)
    return git_run_scope() do
        result, _ = _run_check_pipeline(root; kwargs...)
        result
    end
end

function run_check_pipeline(root::AbstractString; kwargs...)
    kwargs = _normalize_check_inputs!(kwargs)
    return git_run_scope() do
        _run_check_pipeline(root; kwargs...)
    end
end

function ratchet_write!(
        root::AbstractString,
        result::CheckResult,
        contexts::Vector{FileContext};
        merge_scope::Bool = false,
        scope_paths::Set{String} = Set{String}(),
        policy::PolicyBundle,
    )
    path = _ceilings_path(root)
    mkpath(dirname(path))
    viol_counts = count_violation_hits(result.violations)
    exp_counts = count_expect_lines(contexts)
    entry = if merge_scope
        base_entry = isfile(path) ? load_ceilings(root, policy) : CeilingEntry(Dict(), Dict())
        merge_ceiling_entry(base_entry, viol_counts, exp_counts, scope_paths)
    else
        CeilingEntry(viol_counts, exp_counts)
    end
    return write_ceilings_toml!(path, entry)
end
