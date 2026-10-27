# LuaTools macOS

Este paquete es una primera implementación nativa arm64 para macOS 15+.

```bash
swift build -c release
swift run LuaToolsMac
swift run LuaToolsMac --background
./package-plugin.sh
```

La aplicación utiliza `~/Library/Application Support/Steam`, expone el backend local en `127.0.0.1:6767`, instala Lua en `config/stplug-in` y mantiene los manifiestos en `depotcache`. Para activar la dylib de BetterSteamTools de forma explícita:

```bash
BETTERSTEAMTOOLS_MAC_DYLIB=/ruta/BetterSteamTools.dylib swift run LuaToolsMac
```

El cargador objetivo es **LuaLoader**. La aplicación Windows actual instala el loader `winmm.dll` de LTSP y usa `CefInjectorService` para el transporte CDP y el polyfill de `window.Millennium.callServerMethod`. Ese nombre de API no implica una dependencia de Millennium.

El código macOS incluye el transporte CDP y un adaptador Lua heredado, y prioriza el servicio CDP de LuaTools incluso si Millennium está presente. Todavía debe completar el arranque nativo equivalente a LuaLoader. El loader Windows no es ejecutable en Steam nativo macOS.

El instalador del plugin valida el contenido del ZIP y prepara una versión aislada antes de activarla. Conserva una versión anterior, comprueba si sus archivos se han modificado y recupera operaciones interrumpidas. También acepta un SHA-256 esperado cuando se conoce el hash de una distribución confiable. La desactivación detiene nuevas inyecciones; una pestaña que ya cargó el plugin necesita recargarse. La integración con Steam real y la paridad funcional siguen pendientes de validación.
