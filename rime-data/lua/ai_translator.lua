local M = {}

local function trim(text)
    if not text then
        return ""
    end
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function shell_quote(text)
    return "'" .. tostring(text):gsub("'", [['"'"']]) .. "'"
end

local function split_lines(text)
    local lines = {}
    if not text or #text == 0 then
        return lines
    end

    text = text:gsub("\r\n", "\n")
    for line in text:gmatch("[^\n]+") do
        line = trim(line)
        if #line > 0 then
            table.insert(lines, line)
        end
    end
    return lines
end

local function push_commit(env, text)
    text = trim(text)
    if #text == 0 then
        return
    end

    table.insert(env.commit_buffer, text)
    while #env.commit_buffer > env.recent_commit_count do
        table.remove(env.commit_buffer, 1)
    end
end

local function build_context(env)
    if #env.commit_buffer == 0 then
        local latest = env.engine.context.commit_history:latest_text()
        latest = trim(latest or "")
        if #latest == 0 then
            return ""
        end
        return latest
    end

    local context = table.concat(env.commit_buffer, "")
    if #context <= env.max_context_chars then
        return context
    end

    return context:sub(#context - env.max_context_chars + 1)
end

local function make_candidate(seg, text, comment, quality)
    local cand = Candidate("ai", seg.start, seg._end, text, comment or "")
    cand.quality = quality or 100000
    yield(cand)
end

local function resolve_path(home, configured, fallback)
    if configured and #configured > 0 then
        return configured
    end
    return home .. "/Library/Rime/" .. fallback
end

local function run_bridge(env, context)
    local script_path = resolve_path(env.home_dir, env.script_path, "scripts/rime_ai_bridge.py")
    local config_path = resolve_path(env.home_dir, env.config_path, "rime_ai.local.json")
    local command = table.concat({
        shell_quote(env.python_bin),
        shell_quote(script_path),
        "--config", shell_quote(config_path),
        "--context", shell_quote(context),
        "--max-candidates", tostring(env.max_candidates),
        "--timeout", tostring(env.timeout_seconds),
        "2>&1",
    }, " ")

    local handle = io.popen(command)
    if not handle then
        return nil, "bridge unavailable"
    end

    local output = handle:read("*a")
    local ok = handle:close()

    local lines = split_lines(output)
    if lines[1] and lines[1]:match("^ERR\t") then
        return nil, lines[1]:gsub("^ERR\t", "")
    end
    if not ok then
        return nil, lines[1] or "bridge failed"
    end
    if not lines[1] or lines[1] ~= "OK" then
        return nil, lines[1] or "empty response"
    end

    local candidates = {}
    for i = 2, #lines do
        table.insert(candidates, lines[i])
    end

    if #candidates == 0 then
        return nil, "no candidate"
    end
    return candidates, nil
end

function M.init(env)
    local config = env.engine.schema.config
    env.name_space = env.name_space:gsub("^%*", "")
    env.home_dir = os.getenv("HOME") or ""
    env.trigger = config:get_string(env.name_space .. "/trigger") or "zzai"
    env.comment = config:get_string(env.name_space .. "/comment") or "AI"
    env.empty_context_hint = config:get_string(env.name_space .. "/empty_context_hint") or "AI needs recent context"
    env.error_text = config:get_string(env.name_space .. "/error_text") or "AI unavailable"
    env.max_candidates = config:get_int(env.name_space .. "/max_candidates") or 3
    env.recent_commit_count = config:get_int(env.name_space .. "/recent_commit_count") or 12
    env.max_context_chars = config:get_int(env.name_space .. "/max_context_chars") or 240
    env.cache_ttl_seconds = config:get_int(env.name_space .. "/cache_ttl_seconds") or 15
    env.timeout_seconds = config:get_int(env.name_space .. "/timeout_seconds") or 8
    env.python_bin = config:get_string(env.name_space .. "/python_bin") or "/usr/bin/python3"
    env.config_path = config:get_string(env.name_space .. "/config_path") or ""
    env.script_path = config:get_string(env.name_space .. "/script_path") or ""
    env.cache = {}
    env.commit_buffer = {}

    env.commit_notifier = env.engine.context.commit_notifier:connect(function(ctx)
        push_commit(env, ctx:get_commit_text())
    end)
end

function M.func(input, seg, env)
    if input ~= env.trigger then
        return
    end

    local context = build_context(env)
    if #context == 0 then
        make_candidate(seg, env.error_text, env.empty_context_hint, 100001)
        return
    end

    local cache_key = context
    local cached = env.cache[cache_key]
    if cached and (os.time() - cached.ts) <= env.cache_ttl_seconds then
        for _, text in ipairs(cached.items) do
            make_candidate(seg, text, env.comment, 100000)
        end
        return
    end

    local items, err = run_bridge(env, context)
    if not items then
        make_candidate(seg, env.error_text, err or env.comment, 100001)
        return
    end

    env.cache[cache_key] = {
        ts = os.time(),
        items = items,
    }

    for _, text in ipairs(items) do
        make_candidate(seg, text, env.comment, 100000)
    end
end

function M.fini(env)
    if env.commit_notifier then
        env.commit_notifier:disconnect()
    end
end

return M
