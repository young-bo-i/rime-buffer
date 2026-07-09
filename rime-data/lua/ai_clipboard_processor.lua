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

local function normalize_hotkey(text)
    if not text then
        return ""
    end

    local parts = {}
    for part in tostring(text):gmatch("[^%+]+") do
        local token = trim(part):lower()
        if #token > 0 then
            table.insert(parts, token)
        end
    end
    table.sort(parts)
    return table.concat(parts, "+")
end

local function load_hotkeys(config)
    local hotkeys = {}
    local hotkey_list = config:get_list("ai_clipboard_processor/hotkeys")
    if hotkey_list and hotkey_list.size > 0 then
        for i = 0, hotkey_list.size - 1 do
            local item = hotkey_list:get_value_at(i)
            if item and item.value then
                table.insert(hotkeys, normalize_hotkey(item.value))
            end
        end
    end

    if #hotkeys == 0 then
        local single = config:get_string("key_binder/ai_translate_clipboard")
        if single and #single > 0 then
            table.insert(hotkeys, normalize_hotkey(single))
        end
    end

    if #hotkeys == 0 then
        hotkeys = {
            normalize_hotkey("Control+Shift+e"),
            normalize_hotkey("F8"),
            normalize_hotkey("Shift+F8"),
        }
    end

    return hotkeys
end

local function resolve_path(home, configured, fallback)
    if configured and #configured > 0 then
        return configured
    end
    return home .. "/Library/Rime/" .. fallback
end

local function run_clipboard_translate(env)
    local script_path = resolve_path(
        env.home_dir,
        env.script_path,
        "scripts/rime_ai_clipboard.py"
    )
    local config_path = resolve_path(env.home_dir, env.config_path, "rime_ai.local.json")
    local command = table.concat({
        shell_quote(env.python_bin),
        shell_quote(script_path),
        "--config", shell_quote(config_path),
        "--timeout", tostring(env.timeout_seconds),
        "2>&1",
    }, " ")

    local handle = io.popen(command)
    if not handle then
        return nil, "bridge unavailable"
    end

    local output = handle:read("*a") or ""
    local ok = handle:close()
    output = output:gsub("\r\n", "\n")

    local lines = {}
    for line in output:gmatch("[^\n]+") do
        table.insert(lines, line)
    end

    if lines[1] and lines[1]:match("^ERR\t") then
        return nil, lines[1]:gsub("^ERR\t", "")
    end
    if not ok then
        return nil, trim(lines[1] or "translation failed")
    end
    if not lines[1] or lines[1] ~= "OK" then
        return nil, trim(lines[1] or "invalid response")
    end

    local translated = trim(table.concat(lines, "\n", 2))
    if #translated == 0 then
        return nil, "empty translation"
    end
    return translated, nil
end

function M.init(env)
    local config = env.engine.schema.config
    env.home_dir = os.getenv("HOME") or ""
    env.hotkeys = load_hotkeys(config)
    env.python_bin = config:get_string("ai_clipboard_processor/python_bin") or "/usr/bin/python3"
    env.config_path = config:get_string("ai_clipboard_processor/config_path") or ""
    env.script_path = config:get_string("ai_clipboard_processor/script_path") or ""
    env.timeout_seconds = config:get_int("ai_clipboard_processor/timeout_seconds") or 12
end

function M.func(key, env)
    if key:release() then
        return 2
    end

    local key_repr = normalize_hotkey(key:repr())
    local matched = false
    for _, hotkey in ipairs(env.hotkeys) do
        if key_repr == hotkey then
            matched = true
            break
        end
    end
    if not matched then
        return 2
    end

    local context = env.engine.context
    if context:is_composing() or context:has_menu() then
        return 2
    end

    local translated, err = run_clipboard_translate(env)
    if not translated then
        if err and log and log.error then
            log.error("[ai_clipboard_processor] " .. err)
        end
        return 1
    end

    env.engine:commit_text(translated)
    context:clear()
    return 1
end

return M
