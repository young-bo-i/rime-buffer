local M = {}
local actions = require("ai_box_actions")
local view = require("ai_box_view")

local kAccepted = 1
local kNoop = 2
local cleanup_job
local kResultSeparator = "\31"

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
        table.insert(lines, line)
    end
    return lines
end

local function delete_last_utf8(text)
    if not text or text == "" then
        return ""
    end

    local start_pos = utf8.offset(text, -1)
    if not start_pos then
        return ""
    end
    return text:sub(1, start_pos - 1)
end

local function resolve_path(home, configured, fallback)
    if configured and #configured > 0 then
        return configured
    end
    return home .. "/Library/Rime/" .. fallback
end

local function read_file(path)
    local handle = io.open(path, "r")
    if not handle then
        return nil
    end
    local text = handle:read("*a")
    handle:close()
    return text
end

local function write_file(path, text)
    local handle = io.open(path, "w")
    if not handle then
        return false
    end
    handle:write(text or "")
    handle:close()
    return true
end

local function remove_file(path)
    if path and #path > 0 then
        os.remove(path)
    end
end

local function ensure_dir(path)
    os.execute("mkdir -p " .. shell_quote(path))
end

local function sleep_seconds(seconds)
    os.execute("/bin/sleep " .. tostring(seconds))
end

local function ai_mode_enabled(context)
    return context.get_option and context:get_option("ai_mode")
end

local function set_ai_mode(context, enabled)
    if context.set_option then
        context:set_option("ai_mode", enabled)
    end
end

local function set_ascii_mode(context, enabled)
    if context.set_option then
        context:set_option("ascii_mode", enabled)
    end
end

local function is_idle_ui(env, context)
    return (context.input or "") == env.idle_code
end

local function show_idle_ui(env, force_rebuild)
    local context = env.engine.context
    if not force_rebuild and (context.input or "") == env.idle_code then
        context:refresh_non_confirmed_composition()
        return
    end

    context:clear()
    context:push_input(env.idle_code)
    context:refresh_non_confirmed_composition()
end

local function should_start_new_input(key)
    if key:ctrl() or key:alt() or key:super() then
        return false
    end

    local ch = key.keycode
    if ch >= 0x21 and ch <= 0x7E then
        return true
    end
    if ch >= 0xFFB0 and ch < 0xFFBA then
        return true
    end
    return false
end

local function set_error(env, text)
    env.engine.context:set_property("ai_box_error", trim(text or ""))
end

local function set_runtime_property(env, key, value)
    env.engine.context:set_property(key, value or "")
end

local function result_menu_visible(env)
    return (env.engine.context:get_property("ai_box_result_menu_visible") or "") == "1"
end

local function set_result_menu_visible(env, visible)
    set_runtime_property(env, "ai_box_result_menu_visible", visible and "1" or "")
end

local function action_menu_visible(env)
    return (env.engine.context:get_property("ai_box_action_menu_visible") or "") == "1"
end

local function set_action_menu_visible(env, visible)
    set_runtime_property(env, "ai_box_action_menu_visible", visible and "1" or "")
end

local function reset_runtime_state(env)
    set_runtime_property(env, "ai_box_phase", "")
    set_runtime_property(env, "ai_box_spinner", "")
    set_runtime_property(env, "ai_box_stream_output", "")
    set_runtime_property(env, "ai_box_active_action_label", "")
    set_action_menu_visible(env, false)
    set_result_menu_visible(env, false)
    set_runtime_property(env, "ai_box_result_items", "")
end

local function set_waiting_state(env, spinner, output)
    set_runtime_property(env, "ai_box_phase", "waiting")
    set_runtime_property(env, "ai_box_spinner", spinner or "")
    set_runtime_property(env, "ai_box_stream_output", output or "")
end

local function has_pending_job(env)
    return env.pending_job ~= nil
end

local function clear_pending_job(env, cleanup_files)
    local job = env.pending_job
    env.pending_job = nil
    if cleanup_files and job then
        cleanup_job(job)
    end
    return job
end

local function sync_buffer(env)
    env.engine.context:set_property("ai_box_buffer", env.buffer or "")
    env.engine.context:set_property("ai_box_lines", "")
    env.engine.context:set_property("ai_box_active_line", "")
end

local function has_buffer_content(env)
    return trim(env.buffer or "") ~= ""
end

local function append_buffer(env, text)
    if not text or text == "" then
        return
    end
    env.buffer = (env.buffer or "") .. text
    sync_buffer(env)
end

local function delete_buffer_char(env)
    if not env.buffer or env.buffer == "" then
        return false
    end
    env.buffer = delete_last_utf8(env.buffer)
    sync_buffer(env)
    return true
end

local function clear_state(env)
    env.buffer = ""
    sync_buffer(env)
    set_error(env, "")
    reset_runtime_state(env)
end

local function restore_ascii_mode(context)
    local was_enabled = (context:get_property("ai_box_prev_ascii_mode") or "") == "1"
    context:set_property("ai_box_prev_ascii_mode", "")
    set_ascii_mode(context, was_enabled)
end

local function exit_ai_mode(env)
    local context = env.engine.context
    clear_state(env)
    clear_pending_job(env, false)
    set_ai_mode(context, false)
    restore_ascii_mode(context)
    context:clear()
end

local function show_action_menu(env, force_rebuild)
    set_result_menu_visible(env, false)
    set_action_menu_visible(env, true)
    show_idle_ui(env, force_rebuild)
end

local function split_result_items(text)
    local items = {}
    local seen = {}

    for _, raw in ipairs(split_lines(text or "")) do
        local line = trim(raw)
        if line ~= "" and not seen[line] then
            seen[line] = true
            table.insert(items, line)
        end
    end

    return items
end

local function get_result_items(env)
    local raw = env.engine.context:get_property("ai_box_result_items") or ""
    local items = {}
    if raw == "" then
        return items
    end

    for item in raw:gmatch("([^" .. kResultSeparator .. "]+)") do
        local text = trim(item)
        if text ~= "" then
            table.insert(items, text)
        end
    end
    return items
end

local function show_result_menu(env, action, output)
    local items = split_result_items(output)
    if #items == 0 then
        return false
    end

    set_action_menu_visible(env, false)
    set_result_menu_visible(env, true)
    set_runtime_property(env, "ai_box_phase", "result_select")
    set_runtime_property(env, "ai_box_active_action_label", action.label)
    set_runtime_property(env, "ai_box_result_items", table.concat(items, kResultSeparator))
    set_runtime_property(env, "ai_box_stream_output", "")
    set_runtime_property(env, "ai_box_spinner", "")
    show_idle_ui(env, true)
    return true
end

local function refresh_idle_display(env, force_rebuild)
    local context = env.engine.context
    if has_pending_job(env) then
        show_idle_ui(env, force_rebuild)
        return
    end
    if result_menu_visible(env) then
        show_idle_ui(env, force_rebuild)
        return
    end
    if action_menu_visible(env) then
        show_action_menu(env, force_rebuild)
        return
    end
    if has_buffer_content(env) or trim(context:get_property("ai_box_error") or "") ~= "" then
        show_idle_ui(env, force_rebuild)
        return
    end
    if is_idle_ui(env, context) then
        context:clear()
    end
end

local function hide_action_menu(env)
    set_action_menu_visible(env, false)
    refresh_idle_display(env, true)
end

local function is_action_menu_open(env, context)
    return is_idle_ui(env, context) and action_menu_visible(env)
end

local function is_result_menu_open(env, context)
    return is_idle_ui(env, context) and result_menu_visible(env)
end

local function get_selected_text(context)
    local selected = context:get_selected_candidate()
    if selected and actions.is_internal_candidate_type(selected.type) then
        return ""
    end

    if context:has_menu() and selected and selected.text and #selected.text > 0 then
        return selected.text
    end

    local raw_input = context.input or ""
    if #raw_input > 0 then
        return raw_input
    end

    return ""
end

local function get_candidate_text_at_index(context, index)
    local composition = context.composition
    if not composition or composition:empty() then
        return ""
    end

    local segment = composition:back()
    if not segment or not segment.get_candidate_at then
        return ""
    end

    local cand = segment:get_candidate_at(index)
    if not cand or actions.is_internal_candidate_type(cand.type) or not cand.text or cand.text == "" then
        return ""
    end

    return cand.text
end

local function collect_current_input(env)
    local context = env.engine.context
    if is_idle_ui(env, context) then
        return false
    end

    local text = get_selected_text(context)
    if #text == 0 then
        return false
    end

    append_buffer(env, text)
    context:clear()
    hide_action_menu(env)
    set_error(env, "")
    return true
end

local function collect_raw_input(env)
    local context = env.engine.context
    if is_idle_ui(env, context) then
        return false
    end

    local raw_input = trim(context.input or "")
    if #raw_input == 0 then
        return false
    end

    append_buffer(env, raw_input)
    context:clear()
    hide_action_menu(env)
    set_error(env, "")
    return true
end

local function select_index(key, env)
    local ch = key.keycode
    if ch >= 0x30 and ch <= 0x39 then
        return (ch - 0x30 + 9) % 10
    end
    if ch >= 0xFFB0 and ch < 0xFFBA then
        return (ch - 0xFFB0 + 9) % 10
    end
    return -1
end

local function resolve_selected_action(env, context, action_override)
    if action_override then
        return action_override
    end

    local selected = context:get_selected_candidate()
    if selected and selected.type then
        local action = actions.find_by_candidate_type(selected.type)
        if action then
            return action
        end
    end

    local action = actions.find_by_task(env.default_task)
    if action then
        return action
    end
    return actions.find_by_task(actions.default_task())
end

local function resolve_selected_result(env, context, index_override)
    local items = get_result_items(env)
    if #items == 0 then
        return ""
    end

    if index_override and index_override >= 1 and index_override <= #items then
        return items[index_override]
    end

    local selected = context:get_selected_candidate()
    if selected and selected.type == "ai_box_result_item" and selected.text and selected.text ~= "" then
        return selected.text
    end

    return items[1] or ""
end

local function run_ai_task(env, task, text)
    local script_path = resolve_path(env.home_dir, env.script_path, "scripts/rime_ai_bridge.py")
    local config_path = resolve_path(env.home_dir, env.config_path, "rime_ai.local.json")
    local command = table.concat({
        shell_quote(env.python_bin),
        shell_quote(script_path),
        "--config", shell_quote(config_path),
        "--task", shell_quote(task),
        "--text", shell_quote(text),
        "--timeout", tostring(env.timeout_seconds),
        "2>&1",
    }, " ")

    local handle = io.popen(command)
    if not handle then
        return nil, "bridge unavailable"
    end

    local output = handle:read("*a") or ""
    local ok = handle:close()
    local lines = split_lines(output)
    if lines[1] and lines[1]:match("^ERR\t") then
        return nil, lines[1]:gsub("^ERR\t", "")
    end
    if not ok then
        return nil, trim(lines[1] or "AI request failed")
    end
    if not lines[1] or lines[1] ~= "OK" then
        return nil, trim(lines[1] or "invalid response")
    end

    local content = trim(table.concat(lines, "\n", 2))
    if #content == 0 then
        return nil, "empty AI output"
    end
    return content, nil
end

local function new_job_prefix(env)
    env.job_counter = (env.job_counter or 0) + 1
    local base_dir = resolve_path(env.home_dir, env.job_dir, "tmp/ai_box_jobs")
    ensure_dir(base_dir)
    return string.format("%s/job-%d-%d", base_dir, os.time(), env.job_counter)
end

cleanup_job = function(job)
    if not job then
        return
    end
    remove_file(job.input_file)
    remove_file(job.meta_file)
    remove_file(job.output_file)
    remove_file(job.error_file)
end

local function start_ai_job(env, task, text)
    local worker_path = resolve_path(env.home_dir, env.async_script_path, "scripts/rime_ai_async_worker.py")
    local config_path = resolve_path(env.home_dir, env.config_path, "rime_ai.local.json")
    local prefix = new_job_prefix(env)
    local job = {
        prefix = prefix,
        input_file = prefix .. ".input",
        meta_file = prefix .. ".meta",
        output_file = prefix .. ".out",
        error_file = prefix .. ".err",
    }

    if not write_file(job.input_file, text) then
        return nil, "failed to create AI job input"
    end

    local command_parts = {
        "nohup",
        shell_quote(env.python_bin),
        shell_quote(worker_path),
        "--config", shell_quote(config_path),
        "--task", shell_quote(task),
        "--text-file", shell_quote(job.input_file),
        "--status-prefix", shell_quote(prefix),
        "--timeout", tostring(env.timeout_seconds),
    }
    if env.enable_stream then
        table.insert(command_parts, "--stream")
    end
    table.insert(command_parts, "> /dev/null 2>&1 &")

    os.execute(table.concat(command_parts, " "))
    return job, nil
end

local function start_pending_job(env, action, job)
    env.pending_job = job
    env.pending_job.action = action
    env.pending_job.started_at = os.time()
    env.pending_job.spinner_index = 1
    set_runtime_property(env, "ai_box_active_action_label", action.label)
    set_waiting_state(env, env.spinner_frames[1], "")
end

local function poll_pending_job(env)
    local job = env.pending_job
    if not job then
        return "idle", nil, nil
    end

    local meta = trim(read_file(job.meta_file) or "")
    local output = trim(read_file(job.output_file) or "")

    if meta == "done" then
        clear_pending_job(env, true)
        reset_runtime_state(env)
        return "done", output, nil
    end

    if meta == "error" then
        clear_pending_job(env, true)
        reset_runtime_state(env)
        return "error", nil, trim(read_file(job.error_file) or "AI request failed")
    end

    if job.started_at and (os.time() - job.started_at) > math.ceil(env.wait_timeout_seconds) then
        clear_pending_job(env, false)
        reset_runtime_state(env)
        return "error", nil, "AI request timed out"
    end

    job.spinner_index = (job.spinner_index % #env.spinner_frames) + 1
    set_runtime_property(env, "ai_box_active_action_label", job.action.label)
    set_waiting_state(env, env.spinner_frames[job.spinner_index], output)
    return "running", nil, nil
end

local function format_task_error(env, action, err)
    local prefix = trim(env.error_prefix or "AI 请求失败")
    if prefix:sub(-1) == ":" then
        prefix = trim(prefix:sub(1, -2))
    end
    if prefix:sub(-3) == "：" then
        prefix = trim(prefix:sub(1, -4))
    end
    return string.format("%s（%s）：%s", prefix, action.label, err or "AI request failed")
end

local function finish_pending_job_with_output(env, action, output)
    local context = env.engine.context
    if action and action.task == "find_supporting_references" then
        if show_result_menu(env, action, output) then
            return kAccepted
        end
    end

    clear_state(env)
    context:clear()
    set_ai_mode(context, false)
    restore_ascii_mode(context)
    env.engine:commit_text(output)
    return kAccepted
end

local function finish_pending_job_with_error(env, action, err)
    reset_runtime_state(env)
    set_error(env, format_task_error(env, action, err))
    if log and log.error then
        log.error("[ai_box_processor] " .. action.task .. ": " .. (err or "AI request failed"))
    end
    show_action_menu(env, true)
    return kAccepted
end

local function commit_selected_action(env, action_override)
    local context = env.engine.context
    collect_current_input(env)

    local source = trim(env.buffer or "")
    if #source == 0 then
        set_error(env, "先输入内容")
        show_action_menu(env, true)
        return kAccepted
    end

    local action = resolve_selected_action(env, context, action_override)

    local job, job_err = start_ai_job(env, action.task, source)
    if not job then
        return finish_pending_job_with_error(env, action, job_err)
    end

    start_pending_job(env, action, job)
    show_idle_ui(env, true)
    return kAccepted
end

function M.init(env)
    local config = env.engine.schema.config
    env.home_dir = os.getenv("HOME") or ""
    env.timeout_seconds = config:get_int("ai_box_processor/timeout_seconds") or 12
    env.python_bin = config:get_string("ai_box_processor/python_bin") or "/usr/bin/python3"
    env.config_path = config:get_string("ai_box_processor/config_path") or ""
    env.script_path = config:get_string("ai_box_processor/script_path") or ""
    env.async_script_path = config:get_string("ai_box_processor/async_script_path") or ""
    env.error_prefix = config:get_string("ai_box_processor/error_prefix") or "AI 请求失败："
    env.idle_code = config:get_string("ai_box_status_translator/idle_code") or "zzzzaibox"
    env.job_dir = config:get_string("ai_box_processor/job_dir") or ""
    env.enable_stream = config:get_bool("ai_box_processor/enable_stream")
    if env.enable_stream == nil then
        env.enable_stream = true
    end
    env.poll_interval_seconds = config:get_double("ai_box_processor/poll_interval_seconds") or 0.12
    env.wait_timeout_seconds = config:get_double("ai_box_processor/wait_timeout_seconds")
        or (env.timeout_seconds + 8)
    env.native_refresh_key = config:get_string("ai_box_processor/native_refresh_key") or "F20"
    env.spinner_frames = { "|", "/", "-", "\\" }
    env.default_task = config:get_string("ai_box_processor/default_task") or actions.default_task()
    env.job_counter = 0
    math.randomseed(os.time())
    clear_state(env)
end

function M.func(key, env)
    local context = env.engine.context
    local key_repr = key:repr()

    if not ai_mode_enabled(context) then
        if has_pending_job(env) then
            clear_pending_job(env, false)
            clear_state(env)
        end
        if is_idle_ui(env, context) then
            context:clear()
        end
        return kNoop
    end

    if has_pending_job(env) then
        if not key:release() and key_repr == "Escape" then
            exit_ai_mode(env)
            return kAccepted
        end

        local job = env.pending_job
        local action = job and job.action or actions.find_by_task(env.default_task) or actions.find_by_task(actions.default_task())
        local status, output, err = poll_pending_job(env)
        if status == "done" then
            return finish_pending_job_with_output(env, action, output or "")
        end
        if status == "error" then
            return finish_pending_job_with_error(env, action, err)
        end

        show_idle_ui(env, true)
        return kAccepted
    end

    if key_repr == env.native_refresh_key
        and not key:ctrl()
        and not key:alt()
        and not key:super() then
        return kAccepted
    end

    if (key_repr == "Shift_L" or key_repr == "Shift_R")
        and not key:ctrl()
        and not key:alt()
        and not key:super() then
        return kAccepted
    end

    if key:release() then
        return kNoop
    end

    if key_repr == "Escape" then
        exit_ai_mode(env)
        return kAccepted
    end

    if key_repr == "Return" then
        if is_result_menu_open(env, context) then
            local chosen = resolve_selected_result(env, context)
            if chosen ~= "" then
                clear_state(env)
                context:clear()
                set_ai_mode(context, false)
                restore_ascii_mode(context)
                env.engine:commit_text(chosen)
                return kAccepted
            end
            return kAccepted
        end
        if is_action_menu_open(env, context) then
            return commit_selected_action(env)
        end
        if context:is_composing() or context:has_menu() or #(context.input or "") > 0 then
            if collect_raw_input(env) then
                return kAccepted
            end
        end
        show_action_menu(env, true)
        return kAccepted
    end

    if key_repr == "BackSpace" then
        if is_idle_ui(env, context) then
            if delete_buffer_char(env) then
                refresh_idle_display(env, true)
            else
                refresh_idle_display(env, true)
            end
            return kAccepted
        end
        if context:is_composing() or context:has_menu() or #(context.input or "") > 0 then
            return kNoop
        end
        if delete_buffer_char(env) then
            refresh_idle_display(env, true)
            return kAccepted
        end
        return kNoop
    end

    if not key:shift() and not key:ctrl() and not key:alt() and not key:super() and key.keycode == 0x20 then
        if is_result_menu_open(env, context) then
            local chosen = resolve_selected_result(env, context)
            if chosen ~= "" then
                clear_state(env)
                context:clear()
                set_ai_mode(context, false)
                restore_ascii_mode(context)
                env.engine:commit_text(chosen)
            end
            return kAccepted
        end
        if is_action_menu_open(env, context) then
            return commit_selected_action(env)
        end
        if is_idle_ui(env, context) then
            append_buffer(env, " ")
            return kAccepted
        end
        if context:is_composing() or context:has_menu() or #(context.input or "") > 0 then
            collect_current_input(env)
        else
            append_buffer(env, " ")
        end
        return kAccepted
    end

    if key_repr == "Tab" and not key:shift() and not key:ctrl() and not key:alt() and not key:super() then
        if is_result_menu_open(env, context) then
            local chosen = resolve_selected_result(env, context)
            if chosen ~= "" then
                clear_state(env)
                context:clear()
                set_ai_mode(context, false)
                restore_ascii_mode(context)
                env.engine:commit_text(chosen)
            end
            return kAccepted
        end
        if is_action_menu_open(env, context) then
            return commit_selected_action(env)
        end
        if not context:is_composing() and not context:has_menu() and #(context.input or "") == 0 then
            show_action_menu(env, true)
            return kAccepted
        end
        return kNoop
    end

    if (key_repr == "Up" or key_repr == "Down") and not key:ctrl() and not key:alt() and not key:super() then
        return kNoop
    end

    if context:has_menu() then
        local idx = select_index(key, env)
        if idx >= 0 then
            if is_result_menu_open(env, context) then
                local chosen = resolve_selected_result(env, context, idx + 1)
                if chosen ~= "" then
                    clear_state(env)
                    context:clear()
                    set_ai_mode(context, false)
                    restore_ascii_mode(context)
                    env.engine:commit_text(chosen)
                    return kAccepted
                end
                return kAccepted
            end
            if is_action_menu_open(env, context) then
                local action = actions.list()[idx + 1]
                if action then
                    return commit_selected_action(env, action)
                end
                return kAccepted
            end
            local selected_text = get_candidate_text_at_index(context, idx)
            if #selected_text > 0 then
                append_buffer(env, selected_text)
                context:clear()
                hide_action_menu(env)
                set_error(env, "")
                return kAccepted
            end
            if is_idle_ui(env, context) then
                set_action_menu_visible(env, false)
                context:clear()
                return kNoop
            end
            return kAccepted
        end
    end

    if is_idle_ui(env, context) and should_start_new_input(key) then
        set_action_menu_visible(env, false)
        context:clear()
        return kNoop
    end

    return kNoop
end

return M
