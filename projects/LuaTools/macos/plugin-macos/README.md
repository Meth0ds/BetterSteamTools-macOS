# LuaTools macOS plugin

Esta variante conserva el frontend `luatools.js` y el contrato RPC de LTSP, pero adapta el arranque del backend y las rutas Steam a macOS. Millennium se usa cuando expone su API; el cliente LuaTools mantiene CDP como fallback.

El backend espera LuaTools en `~/Applications/LuaTools.app` o `/Applications/LuaTools.app` y usa el servidor local `http://127.0.0.1:6767`.
