local M = {}

function M.trim(text)
    if not text then
        return ""
    end
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

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

function M.render_buffer(context, opts)
    local buffer = context:get_property("ai_box_buffer") or ""
    return string.format("%s [%s]", opts.preedit_prefix or "AI Box >", buffer)
end

function M.buffer_preview(context, max_chars)
    local buffer = context:get_property("ai_box_buffer") or ""
    buffer = utf8_head(buffer, max_chars or 32)
    if buffer == "" then
        return "(empty)"
    end
    return buffer
end

return M
