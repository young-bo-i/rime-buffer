local M = {}

local kNoop = 2

function M.init(env)
    local config = env.engine.schema.config
    env.target_schema_id = config:get_string("ai_box_trigger_processor/target_schema_id") or "ai_box"
    env.trigger_code = config:get_string("ai_box_trigger_processor/trigger_code") or ",."
    env.switching = false

    env.update_notifier = env.engine.context.update_notifier:connect(function(ctx)
        if env.switching then
            return
        end
        if (ctx.input or "") ~= env.trigger_code then
            return
        end

        env.switching = true
        ctx:clear()
        env.engine:apply_schema(Schema(env.target_schema_id))
        env.switching = false
    end)
end

function M.func(key, env)
    return kNoop
end

function M.fini(env)
    if env.update_notifier then
        env.update_notifier:disconnect()
    end
end

return M
