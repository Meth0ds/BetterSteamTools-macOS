-- Pure Lua tests with Millennium host modules mocked; never starts a process or Steam.
local backend = assert(arg[1], "pass plugin backend directory")
package.path = backend .. "/?.lua;" .. package.path
local state = { calls = {}, commands = {}, written = {}, ready = 0, warnings = {}, healthy = false }
local home = "/Users/Test '$value $(command)"
local data = home .. "/Library/Application Support/Steam"
local client = data .. "/Steam.AppBundle/Steam/Contents/MacOS"
local existing = {
    [data .. "/steamapps"] = true,
    [client .. "/steamui"] = true,
    [home .. "/Applications/LuaTools.app/Contents/MacOS/LuaToolsMac"] = true,
}
local function ends(value, suffix) return value:sub(-#suffix) == suffix end
package.preload.fs = function() return {
    join = function(...) return table.concat({...}, "/") end,
    absolute = function(path) return path end,
    current_path = function() return backend end,
    exists = function(path) return existing[path] or state.written[path] ~= nil or ends(path, "/public/luatools.js") or ends(path, "/public/steamdb-webkit.css") end,
    create_directories = function(path) existing[path] = true end,
} end
package.preload.utils = function() return {
    getenv = function(name) if name == "HOME" then return home end end,
    get_backend_path = function() return backend end,
    read_file = function(path)
        if ends(path, "luatools.js") then return "frontend code"
        elseif ends(path, "steamdb-webkit.css") then return "frontend css"
        elseif ends(path, "themes/themes.json") then return "themes metadata"
        elseif ends(path, "themes/original.css") then return "theme css" end
    end,
    write_file = function(path, value) state.written[path] = value end,
    exec = function(command) table.insert(state.commands, command) end,
} end
package.preload.logger = function() return {
    info = function() end,
    warn = function(_, message) table.insert(state.warnings, message) end,
} end
package.preload.http = function() return {
    get = function() if state.healthy then return {body = state.healthy} end end,
    request = function(url, options) table.insert(state.calls, {url = url, options = options}); return {body = "server response"} end,
} end
package.preload.json = function() return {
    encode = function(value) state.encoded = value; return "encoded JSON" end,
    decode = function(value)
        if value == "themes metadata" then return {{ value = state.themeKey or "original", name = "Original" }}
        elseif value == "healthy" then return { service = "luatools", apiVersion = 1 }
        else return { service = "foreign", apiVersion = 1 } end
    end,
} end
package.preload.millennium = function() return {
    steam_path = function() return client end,
    version = function() return "test-runtime" end,
    add_browser_js = function(path) state.js = path end,
    add_browser_css = function(path) state.css = path end,
    ready = function() state.ready = state.ready + 1 end,
} end
local platform = require("platform")
assert(platform.valid_appid("42") == "42")
assert(platform.valid_appid("42/../../bad") == nil)
assert(platform.valid_appid(-1) == nil)
assert(platform.valid_appid("4294967296") == nil)
assert(platform.valid_appid("0") == nil)
assert(platform.valid_appid(0, true) == "0")
assert(platform.shell_quote("a'b") == "'a'\\''b'")
local plugin = dofile(backend .. "/main.lua")
plugin.on_load()
assert(state.ready == 1)
assert(#state.commands == 1)
assert(state.commands[1] == "/usr/bin/open -g -a " .. platform.shell_quote(home .. "/Applications/LuaTools.app") .. " --args --background")
assert(state.written[client .. "/steamui/webkit/luatools.js"] == "window.__LuaToolsMacAssets = encoded JSON;\nfrontend code")
assert(state.encoded.baseCSS == "frontend css" and state.encoded.themeCSS.original == "theme css")
assert(state.js == "webkit/luatools.js")
assert(state.written[data .. "/steamui/webkit/luatools.js"] == nil)
local count = #state.calls
GetCapabilities()
assert(state.encoded.service == "luatools" and state.encoded.apiVersion == 1 and state.encoded.transport == "millennium")
HasLuaToolsForApp("../invalid")
assert(#state.calls == count and state.encoded.success == false)
assert(HasLuaToolsForApp(42) == "server response")
assert(state.calls[#state.calls].url == "http://127.0.0.1:6767/has/42")
assert(state.calls[#state.calls].options.method == "GET")
StartLuaToolsAdd(42, "Native Game")
assert(state.calls[#state.calls].url == "http://127.0.0.1:6767/add/42")
assert(state.encoded.gameName == "Native Game")
assert(type(_G["Logger.log"]) == "function")
_G["Logger.log"]("message")
assert(state.calls[#state.calls].url == "http://127.0.0.1:6767/log")
for _, name in ipairs({"CheckForFixes", "GetTranslations", "GetThemes", "GetSettingsConfig", "GetGamesDatabase", "GetIconDataUrl", "OpenExternalUrl", "CheckForUpdatesNow"}) do
    assert(type(_G[name]) == "function", "missing RPC handler " .. name)
end
state.healthy = "healthy"
plugin.on_load()
assert(#state.commands == 1, "healthy service must not launch another instance")
state.healthy = "foreign"
plugin.on_load()
assert(#state.commands == 1, "occupied foreign port must not launch another instance")
assert(#state.warnings > 0)
local steam = require("steam_utils")
assert(steam.detect_steam_install_path() == data)
assert(steam.detect_steam_client_path() == client)
assert(steam.get_game_install_path_response("../../x").success == false)
state.themeKey = "../../outside"
local composed, err = require("frontend_assets").compose("public")
assert(composed == nil and err == "Invalid or duplicate theme name")
print("PASS: macOS plugin paths, shell arguments, service identity and RPC forwarding")
