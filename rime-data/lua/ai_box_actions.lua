local M = {}

local actions = {
    {
        task = "translate_to_english",
        candidate_type = "ai_box_action_translate_to_english",
        label = "译英",
    },
    {
        task = "translate_to_chinese",
        candidate_type = "ai_box_action_translate_to_chinese",
        label = "译中",
    },
    {
        task = "paraphrase",
        candidate_type = "ai_box_action_paraphrase",
        label = "改写",
    },
    {
        task = "find_supporting_references",
        candidate_type = "ai_box_action_find_supporting_references",
        label = "文献",
    },
}

local actions_by_task = {}
local actions_by_candidate_type = {}

for _, action in ipairs(actions) do
    actions_by_task[action.task] = action
    actions_by_candidate_type[action.candidate_type] = action
end

function M.list()
    return actions
end

function M.default_task()
    return actions[1].task
end

function M.find_by_task(task)
    return actions_by_task[task]
end

function M.find_by_candidate_type(candidate_type)
    return actions_by_candidate_type[candidate_type]
end

function M.is_internal_candidate_type(candidate_type)
    if candidate_type == "ai_box_status" then
        return true
    end
    if candidate_type == "ai_box_result_item" then
        return true
    end
    return actions_by_candidate_type[candidate_type] ~= nil
end

return M
