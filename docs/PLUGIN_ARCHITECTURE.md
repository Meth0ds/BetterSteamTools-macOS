# LuaTools loader target

The requested macOS port follows the current Windows **LuaLoader** architecture.

Authoritative sources in the imported LuaTools commit:

- `src/LuaToolsGui/Services/PluginInstallerService.cs`: installs the LTSP `winmm.dll` loader, handles the CEF debugging marker and coexists with Millennium.
- `src/LuaToolsGui/Services/CefInjectorService.cs`: connects through CDP, injects the frontend and supplies the `window.Millennium.callServerMethod` compatibility API.
- `src/LuaToolsGui/AppConfig.cs`: pins the LTSP release repository for `plugin.zip` plus `winmm.dll`.
- The upstream wiki labels the old Millennium-only installation method end-of-support: https://github.com/madoiscool/luatools-wiki/blob/main/docs/luatools/steam-plugin/get-started.md

The JavaScript API name `Millennium` is retained for frontend compatibility. It must not be treated as proof that Millennium is the loader or made a mandatory dependency.

macOS work still required: implement the native LuaLoader bootstrap/lifecycle and prove store/library behavior in native Steam. The desktop CDP service now owns LuaTools RPC as its primary route, retains unrelated plugins' RPC behavior and keeps one wrapper with stable pending calls when a legacy Millennium backend appears. `winmm.dll` itself cannot load into a Mach-O process. The legacy Lua backend is compatibility material, not the completed primary loader.
