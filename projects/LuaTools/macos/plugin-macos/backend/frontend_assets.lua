local fs = require("fs")
local utils = require("utils")
local json = require("json")
local M = {}

function M.compose(public_dir)
    local script = utils.read_file(fs.join(public_dir, "luatools.js"))
    local base = utils.read_file(fs.join(public_dir, "steamdb-webkit.css"))
    local metadata = utils.read_file(fs.join(public_dir, "themes", "themes.json"))
    if not script or #script > 1048576 or not base or #base > 262144 or not metadata or #metadata > 65536 then
        return nil, "Missing or oversized frontend assets"
    end
    local ok, themes = pcall(json.decode, metadata)
    if not ok or type(themes) ~= "table" or #themes == 0 or #themes > 64 then return nil, "Invalid themes metadata" end
    local css = {}
    for _, theme in ipairs(themes) do
        local key = type(theme) == "table" and theme.value
        if type(key) ~= "string" or #key == 0 or #key > 48 or not key:match("^[a-z0-9_-]+$") or css[key] then
            return nil, "Invalid or duplicate theme name"
        end
        local text = utils.read_file(fs.join(public_dir, "themes", key .. ".css"))
        if not text or #text > 131072 then return nil, "Missing or oversized theme stylesheet" end
        css[key] = text
    end
    local result = "window.__LuaToolsMacAssets = " .. json.encode({ version = 1, baseCSS = base, themes = themes, themeCSS = css }) .. ";\n" .. script
    if #result > 1500000 then return nil, "Frontend asset bundle too large" end
    return result
end
return M
