local M = {}

local kAccepted = 1
local kNoop = 2

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

local function remember_ascii_mode(context)
    local enabled = context.get_option and context:get_option("ascii_mode")
    context:set_property("ai_box_prev_ascii_mode", enabled and "1" or "")
end

local function restore_ascii_mode(context)
    local was_enabled = (context:get_property("ai_box_prev_ascii_mode") or "") == "1"
    context:set_property("ai_box_prev_ascii_mode", "")
    set_ascii_mode(context, was_enabled)
end

local function clear_ai_state(context)
    context:set_property("ai_box_buffer", "")
    context:set_property("ai_box_error", "")
    context:set_property("ai_box_phase", "")
    context:set_property("ai_box_spinner", "")
    context:set_property("ai_box_stream_output", "")
    context:set_property("ai_box_active_action_label", "")
    context:set_property("ai_box_action_menu_visible", "")
    context:set_property("ai_box_result_menu_visible", "")
    context:set_property("ai_box_result_items", "")
    context:set_property("ai_box_lines", "")
    context:set_property("ai_box_active_line", "")
end

local function show_ai_idle(env)
    local context = env.engine.context
    if (context.input or "") == env.idle_code then
        context:refresh_non_confirmed_composition()
        return
    end

    context:clear()
    context:push_input(env.idle_code)
    context:refresh_non_confirmed_composition()
end

local function enter_ai_mode(env)
    local context = env.engine.context
    clear_ai_state(context)
    remember_ascii_mode(context)
    set_ascii_mode(context, false)
    set_ai_mode(context, true)
    context:clear()
end

local function exit_ai_mode(env)
    local context = env.engine.context
    clear_ai_state(context)
    set_ai_mode(context, false)
    restore_ascii_mode(context)
    context:clear()
end

local function mode_switch_allowed(env)
    local context = env.engine.context
    local input = context.input or ""
    if ai_mode_enabled(context) then
        return input == env.idle_code or (input == "" and not context:is_composing() and not context:has_menu())
    end
    return input == "" and not context:is_composing() and not context:has_menu()
end

function M.init(env)
    local config = env.engine.schema.config
    env.idle_code = config:get_string("mode_switch_processor/idle_code") or "zzzzaibox"
end

function M.func(key, env)
    if key:release() then
        return kNoop
    end

    if key.keycode == 0x20 and key:shift() and not key:ctrl() and not key:alt() and not key:super() then
        if mode_switch_allowed(env) then
            if ai_mode_enabled(env.engine.context) then
                exit_ai_mode(env)
            else
                enter_ai_mode(env)
            end
            return kAccepted
        end
    end

    return kNoop
end

return M
