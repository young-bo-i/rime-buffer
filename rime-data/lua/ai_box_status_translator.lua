local M = {}
local actions = require("ai_box_actions")
local view = require("ai_box_view")

local function utf8_head(text, max_chars)
    if not text or text == "" then
        return ""
    end

    local length = utf8.len(text)
    if not length or length <= max_chars then
        return text
    end

    local cut = utf8.offset(text, max_chars + 1)
    if not cut then
        return text
    end
    return text:sub(1, cut - 1) .. "..."
end

local function build_preedit(env, context)
    return view.render_buffer(context, {
        preedit_prefix = env.preedit_prefix,
    })
end

local function action_menu_visible(context)
    return view.trim(context:get_property("ai_box_action_menu_visible") or "") == "1"
end

local function result_menu_visible(context)
    return view.trim(context:get_property("ai_box_result_menu_visible") or "") == "1"
end

local function has_buffer_content(context)
    return view.trim(context:get_property("ai_box_buffer") or "") ~= ""
end

local function get_result_items(context)
    local items = {}
    local raw = context:get_property("ai_box_result_items") or ""
    if raw == "" then
        return items
    end

    for item in raw:gmatch("([^\31]+)") do
        local text = view.trim(item)
        if text ~= "" then
            table.insert(items, text)
        end
    end

    return items
end

local function build_comment(env, context)
    local error_text = view.trim(context:get_property("ai_box_error") or "")
    if #error_text > 0 then
        return error_text, "error"
    end

    local phase = view.trim(context:get_property("ai_box_phase") or "")
    local spinner = view.trim(context:get_property("ai_box_spinner") or "")
    local streamed = context:get_property("ai_box_stream_output") or ""
    streamed = view.trim(streamed)

    if phase == "waiting" then
        if #streamed > 0 then
            return string.format("%s %s", spinner, utf8_head(streamed, env.comment_preview_chars)), "waiting"
        end
        return string.format("%s %s", spinner, env.waiting_text), "waiting"
    end

    return env.ready_hint, "ready"
end

local function build_status_label(env, context)
    local action_label = view.trim(context:get_property("ai_box_active_action_label") or "")
    if #action_label > 0 then
        return action_label
    end
    return env.label
end

local function build_action_comment(env, context, index)
    local status_comment, state = build_comment(env, context)
    if state == "error" and index == 1 then
        return status_comment
    end
    return ""
end

function M.init(env)
    local config = env.engine.schema.config
    env.name_space = env.name_space:gsub("^%*", "")
    env.idle_code = config:get_string(env.name_space .. "/idle_code") or "zzzzaibox"
    env.label = config:get_string(env.name_space .. "/label") or "〔AI Box〕"
    env.preedit_prefix = config:get_string(env.name_space .. "/preedit_prefix") or "AI Box >"
    env.ready_hint = config:get_string(env.name_space .. "/ready_hint")
        or "↑↓切换 Tab执行"
    env.waiting_text = config:get_string(env.name_space .. "/waiting_text") or "AI 正在生成..."
    env.comment_preview_chars = config:get_int(env.name_space .. "/comment_preview_chars") or 48
end

function M.func(input, seg, env)
    if not (env.engine.context.get_option and env.engine.context:get_option("ai_mode")) then
        return
    end
    if input ~= env.idle_code then
        return
    end

    local preedit = build_preedit(env, env.engine.context)
    local status_comment, state = build_comment(env, env.engine.context)
    if state == "waiting" then
        local cand = Candidate(
            "ai_box_status",
            seg.start,
            seg._end,
            build_status_label(env, env.engine.context),
            status_comment
        )
        cand.quality = 1000000
        cand.preedit = preedit
        yield(cand)
        return
    end

    if result_menu_visible(env.engine.context) then
        for index, item in ipairs(get_result_items(env.engine.context)) do
            local cand = Candidate(
                "ai_box_result_item",
                seg.start,
                seg._end,
                item,
                ""
            )
            cand.quality = 1000000 - index
            cand.preedit = preedit
            yield(cand)
        end
        return
    end

    if not action_menu_visible(env.engine.context) and state ~= "error" then
        if has_buffer_content(env.engine.context) then
            local cand = Candidate(
                "ai_box_status",
                seg.start,
                seg._end,
                build_status_label(env, env.engine.context),
                ""
            )
            cand.quality = 1000000
            cand.preedit = preedit
            yield(cand)
        end
        return
    end

    for index, action in ipairs(actions.list()) do
        local cand = Candidate(
            action.candidate_type,
            seg.start,
            seg._end,
            action.label,
            build_action_comment(env, env.engine.context, index)
        )
        cand.quality = 1000000 - index
        cand.preedit = preedit
        yield(cand)
    end
end

return M
