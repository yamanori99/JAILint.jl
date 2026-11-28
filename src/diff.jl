# Git-backed diff scope for `--diff` (first-parent / explicit base ref, fail-closed).

const DEFAULT_DIFF_BASE = "HEAD^1"

struct DiffFileContext
    path::String
    changed_lines::Set{Int}
    status::Char
end

struct DiffScope
    base_ref::String
    files::Vector{DiffFileContext}
end

"""Single path from `git diff --name-status` (rename/copy records both `path` and `old_path`)."""
struct DiffPathEvent
    status::Char
    path::String
    old_path::String
end

const _DIFF_NAME_STATUS_SINGLE = Set(['A', 'M', 'D', 'T'])
const _DIFF_NAME_STATUS_PAIR = Set(['R', 'C'])

function verify_diff_base_ref(root::AbstractString, base::AbstractString)
    root = _git_root(root)
    ref = String(base)
    spec = string(ref, "^{commit}")
    prefix = if ref == DEFAULT_DIFF_BASE
        "--diff requires git: diff base ref not available: HEAD^1 (shallow clone or single-parent HEAD)"
    else
        "--diff requires git: diff base ref not available: $ref"
    end
    try
        read_git_cmd(root, "rev-parse", "--verify", "--end-of-options", spec; error_prefix = prefix)
        return ref
    catch err
        err isa InterruptException && rethrow()
        err isa GitError && rethrow()
        throw(GitError("$prefix: $(format_error(err))"))
    end
end

function resolve_diff_base_arg(raw)
    raw === nothing && return nothing
    return strip(String(raw))
end

function _git_diff_name_status_cmd(root::AbstractString, base::AbstractString)
    return git_cmd(
        root,
        "-c",
        "diff.renames=true",
        "diff",
        "-z",
        "-M",
        "--no-ext-diff",
        "--no-textconv",
        "--text",
        "--name-status",
        "--end-of-options",
        base,
    )
end

"""Physical newline-delimited line count (`wc -l` semantics for trailing newline)."""
function _newline_delimited_line_count(payload::AbstractString)
    s = String(payload)
    isempty(s) && return 0
    n = count('\n', s)
    return endswith(s, '\n') ? n : n + 1
end

"""Changed lines for a destination path present on disk (status `A` / `R` / `C`)."""
function _whole_destination_changed_lines(root::AbstractString, path::AbstractString)
    ap = joinpath(root, path)
    if isfile(ap)
        n = _newline_delimited_line_count(read(ap, String))
        return Set{Int}(1:max(n, 1))
    end
    return Set{Int}()
end

function _parse_diff_name_status_z(parts::Vector{SubString{String}})
    i = 1
    singles = Tuple{Char, String}[]
    events = DiffPathEvent[]
    while i <= length(parts)
        status = String(parts[i])
        isempty(status) &&
            throw(GitError("malformed git diff name-status: empty status entry"))
        st = status[1]
        i += 1
        if st in _DIFF_NAME_STATUS_PAIR
            i + 1 > length(parts) &&
                throw(GitError("truncated git diff name-status record for status '$status'"))
            oldp = normalize_path(parts[i])
            newp = normalize_path(parts[i + 1])
            i += 2
            push!(singles, (st, newp))
            push!(events, DiffPathEvent(st, newp, oldp))
        elseif st in _DIFF_NAME_STATUS_SINGLE
            i > length(parts) &&
                throw(GitError("truncated git diff name-status record for status '$status'"))
            path = normalize_path(parts[i])
            i += 1
            push!(singles, (st, path))
            push!(events, DiffPathEvent(st, path, ""))
        else
            throw(GitError("unknown git diff name-status '$status'"))
        end
    end
    singles = unique(singles)
    return singles, events
end

function _parse_diff_name_status_payload(payload::AbstractString)
    parts = split(String(payload), '\0'; keepempty = false)
    singles, _ = _parse_diff_name_status_z(parts)
    return singles
end

function _parse_diff_path_events_payload(payload::AbstractString)
    parts = split(String(payload), '\0'; keepempty = false)
    _, events = _parse_diff_name_status_z(parts)
    return events
end

function git_diff_name_status(root::AbstractString, base::AbstractString)
    root = _git_root(root)
    base = verify_diff_base_ref(root, base)
    cmd = _git_diff_name_status_cmd(root, base)
    prefix = "--diff requires git: git diff failed for base=$(base)"
    bytes = try
        _read_git_cmd(cmd; error_prefix = prefix)
    catch err
        err isa InterruptException && rethrow()
        err isa GitError && rethrow()
        throw(GitError("$prefix: $(format_error(err))"))
    end
    isempty(bytes) && return Tuple{Char, String}[]
    return _parse_diff_name_status_payload(String(bytes))
end

function git_diff_path_events(root::AbstractString, base::AbstractString)
    root = _git_root(root)
    base = verify_diff_base_ref(root, base)
    cmd = _git_diff_name_status_cmd(root, base)
    prefix = "--diff requires git: git diff failed for base=$(base)"
    bytes = try
        _read_git_cmd(cmd; error_prefix = prefix)
    catch err
        err isa InterruptException && rethrow()
        err isa GitError && rethrow()
        throw(GitError("$prefix: $(format_error(err))"))
    end
    isempty(bytes) && return DiffPathEvent[]
    return _parse_diff_path_events_payload(String(bytes))
end

const _HUNK_RE = r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"

function _parse_unified_hunk_stats(body::AbstractString)
    lines = Set{Int}()
    nhunks = 0
    old_sum = 0
    new_sum = 0
    for line in split(body, '\n'; keepempty = false)
        m = match(_HUNK_RE, line)
        m === nothing && continue
        nhunks += 1
        cap_old_len = m.captures[2]
        old_len = cap_old_len === nothing ? 1 : parse(Int, cap_old_len)
        cap_new_start = m.captures[3]
        cap_new_start === nothing && continue
        new_start = parse(Int, cap_new_start)
        cap_new_len = m.captures[4]
        new_len = cap_new_len === nothing ? 1 : parse(Int, cap_new_len)
        old_sum += old_len
        new_sum += new_len
        new_len > 0 || continue
        for ln in new_start:(new_start + new_len - 1)
            push!(lines, ln)
        end
    end
    return (; lines, nhunks, old_sum, new_sum)
end

function _parse_unified_hunks(body::AbstractString)
    return _parse_unified_hunk_stats(body).lines
end

function _numstat_line_binary(line::AbstractString)
    parts = split(String(line), '\t'; limit = 3)
    length(parts) >= 2 || return false
    return parts[1] == "-" && parts[2] == "-"
end

function _numstat_add_del(line::AbstractString)
    line = String(line)
    _numstat_line_binary(line) && return (0, 0)
    parts = split(line, '\t'; limit = 3)
    length(parts) >= 2 ||
        throw(GitError("malformed git diff --numstat line: $(repr(line))"))
    added = tryparse(Int, parts[1])
    deleted = tryparse(Int, parts[2])
    (added === nothing || deleted === nothing) &&
        throw(GitError("malformed git diff --numstat line: $(repr(line))"))
    return added, deleted
end

"""Sum add/del for a single-path or full `--numstat` payload (one or more lines)."""
function _numstat_totals(payload::AbstractString)
    added = 0
    deleted = 0
    any_binary = false
    for line in split(String(payload), '\n'; keepempty = false)
        _numstat_line_binary(line) && (any_binary = true; continue)
        a, d = _numstat_add_del(line)
        added += a
        deleted += d
    end
    return added, deleted, any_binary
end

function _numstat_line_from_stats(stats::AbstractString, path::AbstractString)
    parts = split(String(stats), '\t'; limit = 3)
    length(parts) >= 2 ||
        throw(GitError("malformed git diff --numstat -z stats: $(repr(stats))"))
    return parts[1] * "\t" * parts[2] * "\t" * normalize_path(path)
end

"""
Parse `git diff -z --numstat -M` into path → `add\\tdel\\tpath` lines (keys match name-status paths).
Rename/copy records use `add\\tdel\\t\\0old\\0new`.
"""
function _parse_numstat_z_by_path(payload::AbstractString)
    parts = split(String(payload), '\0'; keepempty = false)
    out = Dict{String, String}()
    i = 1
    while i <= length(parts)
        rec = String(parts[i])
        tabs = split(rec, '\t'; limit = 3)
        length(tabs) >= 2 ||
            throw(GitError("malformed git diff --numstat -z record: $(repr(rec))"))
        if length(tabs) >= 3 && !isempty(tabs[3])
            path = normalize_path(tabs[3])
            _numstat_add_del(rec) # validate
            out[path] = rec
            i += 1
        else
            i + 2 > length(parts) &&
                throw(GitError("truncated git diff --numstat -z rename/copy record"))
            oldp = normalize_path(parts[i + 1])
            newp = normalize_path(parts[i + 2])
            line_new = _numstat_line_from_stats(rec, newp)
            line_old = _numstat_line_from_stats(rec, oldp)
            _numstat_add_del(line_new)
            out[newp] = line_new
            out[oldp] = line_old
            i += 3
        end
    end
    return out
end

function _diff_has_unified_hunk(body::AbstractString)
    for line in split(body, '\n'; keepempty = false)
        match(_HUNK_RE, line) === nothing || return true
    end
    return false
end

function _diff_has_content_delta(body::AbstractString)
    for line in split(body, '\n'; keepempty = false)
        (startswith(line, "+") && !startswith(line, "+++")) && return true
        (startswith(line, "-") && !startswith(line, "---")) && return true
    end
    return false
end

"""Unified diff has mode metadata only (no `@@` hunks)."""
function _diff_mode_only_metadata(body::AbstractString)
    _diff_has_unified_hunk(body) && return false
    for line in split(body, '\n'; keepempty = false)
        startswith(line, "old mode ") && return true
        startswith(line, "new mode ") && return true
    end
    return false
end

"""Unified diff has rename/copy metadata only (no content `+`/`-` lines)."""
function _diff_pure_rename_copy_metadata(body::AbstractString)
    _diff_has_unified_hunk(body) && return false
    _diff_has_content_delta(body) && return false
    for line in split(body, '\n'; keepempty = false)
        occursin("rename from", line) && return true
        occursin("rename to", line) && return true
        startswith(line, "copy from") && return true
        startswith(line, "copy to") && return true
        startswith(line, "similarity index ") && return true
    end
    return false
end

function _git_diff_path_args(path_status::Char, path::AbstractString, old_path::AbstractString)
    p = normalize_path(path)
    if path_status in _DIFF_NAME_STATUS_PAIR
        o = normalize_path(old_path)
        !isempty(o) || throw(GitError("git diff path pairing missing old path for status=$(path_status) path=$(p)"))
        return [o, p]
    end
    return [p]
end

function _git_diff_numstat_cmd(
        root::AbstractString,
        base::AbstractString;
        text::Bool,
        path_status::Char = 'M',
        path = nothing,
        old_path::AbstractString = "",
    )
    args = String[
        "-c",
        "diff.renames=true",
        "diff",
        "-z",
        "-M",
        "--numstat",
        "--no-ext-diff",
        "--no-textconv",
    ]
    text && push!(args, "--text")
    append!(args, ["--end-of-options", base])
    if path !== nothing
        append!(args, ["--"])
        append!(args, _git_diff_path_args(path_status, String(path), old_path))
    end
    return git_cmd(root, args...)
end

function _git_diff_unified_cmd(
        root::AbstractString,
        base::AbstractString,
        path_status::Char,
        path::AbstractString,
        old_path::AbstractString,
    )
    args = String[
        "-c",
        "diff.renames=true",
        "diff",
        "-U0",
        "-M",
        "--no-color",
        "--no-ext-diff",
        "--no-textconv",
        "--text",
        "--end-of-options",
        base,
        "--",
    ]
    append!(args, _git_diff_path_args(path_status, path, old_path))
    return git_cmd(root, args...)
end

function _git_diff_numstat_maps(root::AbstractString, base::AbstractString, prefix::AbstractString)
    text_bytes = try
        _read_git_cmd(_git_diff_numstat_cmd(root, base; text = true); error_prefix = prefix)
    catch err
        err isa InterruptException && rethrow()
        err isa GitError && rethrow()
        throw(GitError("$prefix: $(format_error(err))"))
    end
    probe_bytes = try
        _read_git_cmd(_git_diff_numstat_cmd(root, base; text = false); error_prefix = prefix)
    catch err
        err isa InterruptException && rethrow()
        err isa GitError && rethrow()
        throw(GitError("$prefix: $(format_error(err))"))
    end
    return (
        _parse_numstat_z_by_path(String(text_bytes)),
        _parse_numstat_z_by_path(String(probe_bytes)),
    )
end

function _numstat_lines_for_path(
        text_map::Dict{String, String},
        probe_map::Dict{String, String},
        path::AbstractString,
        require_present::Bool,
    )
    p = normalize_path(path)
    if require_present
        haskey(text_map, p) ||
            throw(GitError("git diff --numstat --text missing path=$(p) (fail closed)"))
        haskey(probe_map, p) ||
            throw(GitError("git diff --numstat probe missing path=$(p) (fail closed)"))
    end
    text_line = get(text_map, p, "")
    probe_line = get(probe_map, p, "")
    numstat_text = isempty(text_line) ? "" : text_line * "\n"
    numstat_probe = isempty(probe_line) ? "" : probe_line * "\n"
    return numstat_text, numstat_probe
end

"""
    _changed_lines_from_diff_output(body, numstat_text, numstat_probe, path) -> Set{Int}

Parse `git diff -U0 --text` into new-side line numbers. `numstat_probe` is `git diff
--numstat` without `--text` (binary paths use `-\\t-\\t`). Empty hunks are allowed
only for mode-only or pure rename/copy metadata; otherwise fail closed.
"""
function _changed_lines_from_diff_output(
        body::AbstractString,
        numstat_text::AbstractString,
        numstat_probe::AbstractString,
        path::AbstractString,
    )
    body = String(body)
    path = String(path)
    stats = _parse_unified_hunk_stats(body)
    lines = stats.lines
    _, _, probe_binary = _numstat_totals(numstat_probe)
    if probe_binary && isempty(lines)
        throw(GitError("git diff numstat probe binary for path=$(path) (fail closed)"))
    end
    add, del, text_binary = _numstat_totals(numstat_text)
    if stats.nhunks > 0
        if !text_binary && (stats.new_sum != add || stats.old_sum != del)
            throw(
                GitError(
                    "git diff hunk line counts disagree with numstat for path=$(path): " *
                        "hunks new=$(stats.new_sum) old=$(stats.old_sum); " *
                        "numstat add=$(add) del=$(del)",
                ),
            )
        end
        return lines
    end
    _diff_mode_only_metadata(body) && return lines
    _diff_pure_rename_copy_metadata(body) && return lines
    (add > 0 || del > 0) &&
        throw(GitError("git diff numstat reports content change without hunks for path=$(path)"))
    _diff_has_content_delta(body) &&
        throw(GitError("git diff produced no changed lines for path=$(path) (fail closed)"))
    return lines
end

function git_diff_changed_lines(
        root::AbstractString,
        base::AbstractString,
        relpath::AbstractString;
        numstat_text_map = nothing,
        numstat_probe_map = nothing,
        path_status::Char = 'M',
        old_path::AbstractString = "",
    )
    root = _git_root(root)
    base = verify_diff_base_ref(root, base)
    path = normalize_path(relpath)
    unified = _git_diff_unified_cmd(root, base, path_status, path, old_path)
    prefix = "--diff requires git: git diff failed for base=$(base) path=$(path)"
    body = try
        String(_read_git_cmd(unified; error_prefix = prefix))
    catch err
        err isa InterruptException && rethrow()
        err isa GitError && rethrow()
        throw(GitError("$prefix: $(format_error(err))"))
    end
    require_numstat = path_status in ('M', 'R', 'C')
    numstat_text, numstat_probe = if numstat_text_map === nothing
        raw_text = try
            String(
                _read_git_cmd(
                    _git_diff_numstat_cmd(
                        root,
                        base;
                        text = true,
                        path = path,
                        path_status = path_status,
                        old_path = old_path,
                    );
                    error_prefix = prefix,
                ),
            )
        catch err
            err isa InterruptException && rethrow()
            err isa GitError && rethrow()
            throw(GitError("$prefix: $(format_error(err))"))
        end
        raw_probe = try
            String(
                _read_git_cmd(
                    _git_diff_numstat_cmd(
                        root,
                        base;
                        text = false,
                        path = path,
                        path_status = path_status,
                        old_path = old_path,
                    );
                    error_prefix = prefix,
                ),
            )
        catch err
            err isa InterruptException && rethrow()
            err isa GitError && rethrow()
            throw(GitError("$prefix: $(format_error(err))"))
        end
        tmap = _parse_numstat_z_by_path(raw_text)
        pmap = _parse_numstat_z_by_path(raw_probe)
        _numstat_lines_for_path(tmap, pmap, path, require_numstat)
    else
        _numstat_lines_for_path(numstat_text_map, numstat_probe_map, path, require_numstat)
    end
    return _changed_lines_from_diff_output(body, numstat_text, numstat_probe, path)
end

function build_diff_scope(root::AbstractString, base::AbstractString)
    root = _git_root(root)
    base = verify_diff_base_ref(root, base)
    events = git_diff_path_events(root, base)
    old_path_for = Dict{String, String}()
    for ev in events
        ev.status in _DIFF_NAME_STATUS_PAIR && (old_path_for[ev.path] = ev.old_path)
    end
    entries = unique(Tuple{Char, String}[(ev.status, ev.path) for ev in events])
    prefix = "--diff requires git: git diff failed for base=$(base)"
    text_map, probe_map = _git_diff_numstat_maps(root, base, prefix)
    files = DiffFileContext[]
    for (st, path) in entries
        if st == 'D'
            push!(files, DiffFileContext(path, Set{Int}(), st))
            continue
        end
        old_path = get(old_path_for, path, "")
        lines = if st == 'A'
            _whole_destination_changed_lines(root, path)
        elseif st in ('R', 'C')
            git_diff_changed_lines(
                root,
                base,
                path;
                numstat_text_map = text_map,
                numstat_probe_map = probe_map,
                path_status = st,
                old_path = old_path,
            )
            _whole_destination_changed_lines(root, path)
        else
            git_diff_changed_lines(
                root,
                base,
                path;
                numstat_text_map = text_map,
                numstat_probe_map = probe_map,
                path_status = st,
                old_path = old_path,
            )
        end
        push!(files, DiffFileContext(path, lines, st))
    end
    return DiffScope(base, files)
end

function resolve_diff_paths(root::AbstractString; base = nothing, explicit_paths = String[])
    isempty(explicit_paths) || return normalize_path.(explicit_paths)
    base === nothing && return String[]
    return [p for (_, p) in git_diff_name_status(root, base)]
end

function diff_path_status(scope::DiffScope, relpath::AbstractString)
    path = normalize_path(relpath)
    for f in scope.files
        f.path == path && return f.status
    end
    return '\0'
end

function diff_changed_lines(scope::DiffScope, relpath::AbstractString)
    path = normalize_path(relpath)
    for f in scope.files
        f.path == path && return f.changed_lines
    end
    return Set{Int}()
end

function violation_on_changed_lines(d::Violation, changed::Set{Int})
    isempty(changed) && return false
    for ln in d.span.start_line:d.span.end_line
        ln in changed && return true
    end
    return d.anchor_line in changed
end

function _test_integrity_deleted_on_diff(d::Violation, scope::DiffScope, path_events::Vector{DiffPathEvent})
    d.rule_id != "test-integrity" && return false
    d.expect_status != ExpectStatus.DELETED_TEST && return false
    p = normalize_path(d.path)
    p != "test/runtests.jl" && !startswith(p, "test/") && return false
    st = diff_path_status(scope, d.path)
    st == 'D' && return true
    for ev in path_events
        ev.status == 'R' || continue
        normalize_path(ev.old_path) == p && return true
    end
    return false
end

function filter_diff_violations!(
        diags::Vector{Violation},
        scope::DiffScope,
        path_events::Vector{DiffPathEvent} = DiffPathEvent[],
    )
    out = Violation[]
    for d in diags
        st = diff_path_status(scope, d.path)
        if st == 'D'
            _test_integrity_deleted_on_diff(d, scope, path_events) && (push!(out, d); continue)
            continue
        end
        if _test_integrity_deleted_on_diff(d, scope, path_events)
            push!(out, d)
            continue
        end
        changed = diff_changed_lines(scope, d.path)
        violation_on_changed_lines(d, changed) || continue
        push!(out, d)
    end
    return out
end
