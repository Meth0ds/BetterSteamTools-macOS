-- POSIX helpers shared by the macOS plugin lifecycle and folder actions.
local platform = {}
function platform.shell_quote(value)
    assert(type(value) == "string" and not value:find("%z"), "invalid shell argument")
    return "'" .. value:gsub("'", "'\\''") .. "'"
end
function platform.valid_appid(value, allow_zero)
    local text = tostring(value or "")
    if not text:match("^%d+$") then return nil end
    local number = tonumber(text)
    if not number or number > 4294967295 or number < (allow_zero and 0 or 1) then return nil end
    return string.format("%.0f", number)
end
return platform
