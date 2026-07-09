local M = {}
local actions = require("ai_box_actions")
local view = require("ai_box_view")

local function build_preedit(env)
    return view.render_buffer(env.engine.context, {
        preedit_prefix = env.preedit_prefix,
    })
end

function M.init(env)
    local config = env.engine.schema.config
    env.idle_code = config:get_string("ai_box_status_translator/idle_code") or "zzzzaibox"
    env.preedit_prefix = config:get_string("ai_box_status_translator/preedit_prefix") or "AI Box >"
end

function M.func(input, env)
    local context = env.engine.context
    if not (context.get_option and context:get_option("ai_mode")) then
        for cand in input:iter() do
            yield(cand)
        end
        return
    end
    local context_input = context.input or ""
    if context_input == env.idle_code then
        for cand in input:iter() do
            if actions.is_internal_candidate_type(cand.type) then
                yield(cand)
            end
        end
        return
    end

    local preedit = build_preedit(env)
    for cand in input:iter() do
        if not actions.is_internal_candidate_type(cand.type) then
            cand:get_genuine().preedit = preedit
        end
        yield(cand)
    end
end

return M
