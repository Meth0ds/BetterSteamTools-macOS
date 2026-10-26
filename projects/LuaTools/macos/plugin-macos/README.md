# LuaTools macOS plugin

El cargador objetivo es **LuaLoader**, siguiendo el cliente Windows actual. La app macOS compone el frontend `luatools.js` y sus estilos, y atiende su contrato RPC mediante el transporte CDP. Conserva `window.Millennium.callServerMethod` como API compatible para el frontend y mantiene las llamadas de otros plugins; Millennium no es una dependencia principal.

El backend Lua de esta carpeta se conserva como adaptador heredado. El arranque nativo de LuaLoader y la activación en Steam siguen pendientes de implementación y aceptación. La app usa el servicio local `http://127.0.0.1:6767`.
