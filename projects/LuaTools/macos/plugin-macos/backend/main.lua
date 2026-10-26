-- LuaTools injector stub.
-- The real backend is the LuaTools GUI desktop app (HTTP on 127.0.0.1:6767). This lua
-- backend has two jobs:
--   1. Put luatools.js onto the Steam store webkit context (copy into steamui/webkit +
--      Millennium.add_browser_js) — delivery is backend-only in Millennium.
--   2. Be the RPC bridge between the injected page and the app. luatools.js calls
--      window.Millennium.callServerMethod("luatools", "<Name>", args) — under real
--      Millennium that dispatches here (Millennium looks up a GLOBAL Lua function named
--      exactly "<Name>", NOT a member of the table this file returns — see
--      lua_host/main.cc's handle_evaluate). Each RPC function below just relays to the
--      app's HTTP API using Millennium's own http module (server-side, so — unlike a
--      page-context fetch() — it isn't subject to the browser's mixed-content blocking).
--
-- The non-Millennium ("LuaLoader") install mode has its own equivalent bridge:
-- LuaTools GUI's CefInjectorService, which polls the injected page over CDP and makes
-- the same HTTP calls from the app process itself. Any new RPC method added to
-- luatools.js needs a handler in BOTH places, or it only works under one loader.

local millennium  = require("millennium")
local fs          = require("fs")
local m_utils     = require("utils")
local logger      = require("plugin_logger")
local paths       = require("paths")
local steam_utils = require("steam_utils")
local http        = require("http")
local cjson       = require("json")
local platform    = require("platform")
local frontend_assets = require("frontend_assets")

-- ── App backend bridge (127.0.0.1:6767) ────────────────────────────────────────

local BACKEND_BASE = "http://127.0.0.1:6767"

local function backend_request(method, path, body)
    local opts = { method = method, timeout = 15 }
    if body then
        opts.data = cjson.encode(body)
        opts.headers = { ["Content-Type"] = "application/json" }
    end
    local response, err = http.request(BACKEND_BASE .. path, opts)
    if not response then
        return cjson.encode({ success = false, error = tostring(err or "request failed") })
    end
    return response.body
end

-- ── Ensure the app is running ──────────────────────────────────────────────────
-- Mirrors what the non-Millennium DLL hijack does (launch_luatools() in
-- steampluginback/src/lib.rs) — that code never runs under Millennium (Millennium owns
-- wsock32.dll instead), so nothing else brings the backend up in this mode.

local function ensure_backend_running()
    local response = http.get(BACKEND_BASE .. "/health", { timeout = 2 })
    if response then
        local ok, health = pcall(cjson.decode, response.body or "")
        if ok and type(health) == "table" and health.service == "luatools" and health.apiVersion == 1 then return true end
        logger.warn("Port 6767 is occupied by a service that is not a compatible LuaTools backend")
        return false
    end
    local home = m_utils.getenv("HOME")
    if not home or home == "" then
        logger.warn("HOME not available, cannot launch LuaTools backend")
        return false
    end
    local app_path = home .. "/Applications/LuaTools.app"
    if not fs.exists(fs.join(app_path, "Contents", "MacOS", "LuaToolsMac")) then
        app_path = "/Applications/LuaTools.app"
    end
    if not fs.exists(fs.join(app_path, "Contents", "MacOS", "LuaToolsMac")) then
        logger.warn("LuaTools.app is not installed")
        return false
    end
    m_utils.exec("/usr/bin/open -g -a " .. platform.shell_quote(app_path) .. " --args --background")
    logger.log("Requested LuaTools backend startup")
    return true
end

-- ── RPC handlers (must be GLOBAL functions — Millennium looks these up by name) ─

local function app_request(method, endpoint, appid, body, allow_zero)
    local id = platform.valid_appid(appid, allow_zero)
    if not id then return cjson.encode({ success = false, error = "Invalid AppID" }) end
    return backend_request(method, endpoint .. "/" .. id, body)
end
function GetCapabilities()
    return cjson.encode({ service = "luatools", apiVersion = 1, transport = "millennium" })
end
function HasLuaToolsForApp(appid) return app_request("GET", "/has", appid, nil, true) end
function DeleteLuaToolsForApp(appid) return app_request("POST", "/remove", appid) end
function CheckApisForApp(appid) return app_request("POST", "/check-sources", appid) end
function StartAddViaLuaToolsFromUrl(appid, source) return app_request("POST", "/download", appid, { source = source }) end
function GetAddViaLuaToolsStatus(appid) return app_request("GET", "/download-status", appid) end
function CancelAddViaLuaTools(appid) return app_request("POST", "/cancel", appid) end
function StartLuaToolsAdd(appid, gameName) return app_request("POST", "/add", appid, { gameName = gameName }) end
function GetLuaToolsAddStatus(appid) return app_request("GET", "/add-status", appid) end
function PickLuaToolsAddSource(appid, source) return app_request("POST", "/add-source", appid, { source = source }) end
function OpenFix(appid) return app_request("POST", "/open/fix", appid) end
function CheckForFixes(appid) return app_request("GET", "/fixes", appid) end
function RestartSteam() return backend_request("POST", "/restart-steam") end
function OpenSettings() return backend_request("POST", "/open/settings") end
function ReadLoadedApps() return backend_request("GET", "/loaded-apps") end
function DismissLoadedApps() return backend_request("POST", "/loaded-apps") end
function OpenExternalUrl(url) return backend_request("POST", "/open-url", { url = url }) end
function CheckForUpdatesNow() return backend_request("POST", "/check-updates") end
function GetGamesDatabase() return backend_request("GET", "/games-database") end
function GetIconDataUrl() return backend_request("GET", "/icon") end
function GetApiList() return backend_request("GET", "/api-list") end
function GetSettingsConfig() return backend_request("GET", "/settings") end
function GetThemes() return backend_request("GET", "/themes") end
function GetInitApisMessage() return backend_request("GET", "/init-message") end
function GetTranslations(language) return backend_request("POST", "/translations", { language = language }) end
Logger = Logger or {}
function Logger.log(message) return backend_request("POST", "/log", { message = tostring(message or "") }) end
_G["Logger.log"] = Logger.log

-- ── Webkit file management (lifted verbatim from the old backend) ─────────────

local function copy_webkit_files()
    local steam_dir = steam_utils.detect_steam_client_path()
    if not steam_dir or steam_dir == "" then return false end

    local steamui_dir = fs.join(steam_dir, "steamui")
    if not fs.exists(steamui_dir) then return false end
    local target_webkit_dir = fs.join(steamui_dir, "webkit")
    if not fs.exists(target_webkit_dir) then
        fs.create_directories(target_webkit_dir)
    end

    local public_dir = fs.join(paths.get_plugin_dir(), "public")

    local src_js = fs.join(public_dir, "luatools.js")
    local dst_js = fs.join(target_webkit_dir, "luatools.js")
    if fs.exists(src_js) then
        local content, err = frontend_assets.compose(public_dir)
        if not content then logger.warn("Cannot compose LuaTools frontend: " .. tostring(err)); return false end
        m_utils.write_file(dst_js, content)
    end

    local src_css = fs.join(public_dir, "steamdb-webkit.css")
    local dst_css = fs.join(target_webkit_dir, "steamdb-webkit.css")
    if fs.exists(src_css) then
        local content = m_utils.read_file(src_css)
        if content then m_utils.write_file(dst_css, content) end
    end
    return fs.exists(dst_js)
end

local function inject_webkit_files()
    millennium.add_browser_css("webkit/steamdb-webkit.css")
    millennium.add_browser_js("webkit/luatools.js")
end

-- ── Lifecycle ────────────────────────────────────────────────────────────────

local function on_load()
    logger.log("LuaTools injector stub loading (millennium " .. tostring(millennium.version()) .. ")")
    ensure_backend_running()
    if copy_webkit_files() then inject_webkit_files()
    else logger.warn("Steam webkit path is unavailable; frontend injection skipped") end
    millennium.ready()
end

local function on_unload()
    logger.log("LuaTools injector stub unloading")
end

local function on_frontend_loaded()
    -- Re-copy so an updated luatools.js is picked up without a manual step.
    copy_webkit_files()
end

return {
    on_load            = on_load,
    on_unload          = on_unload,
    on_frontend_loaded = on_frontend_loaded,
}
