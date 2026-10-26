/* Native CDP transport only. UI readiness belongs to the unmodified LuaTools frontend. */
(async function () {
    "use strict";
    if (location.origin !== "https://store.steampowered.com") return { transport: "excluded" };
    const version = 1;
    const old = window.__LuaToolsMacTransport;
    const millennium = window.Millennium;
    // Preserve another plugin's receiver and argument contract exactly.
    const nativeCall = old && old.owner === millennium && millennium.callServerMethod === old.wrapper
        ? old.nativeCall : millennium && typeof millennium.callServerMethod === "function"
            ? millennium.callServerMethod.bind(millennium) : null;
    let timer;
    try {
        if (nativeCall) {
            const capability = await Promise.race([
                Promise.resolve(nativeCall("luatools", "GetCapabilities", {})),
                new Promise((_, reject) => { timer = setTimeout(() => reject(new Error("Millennium handshake timed out")), 750); })
            ]);
            const result = typeof capability === "string" ? JSON.parse(capability) : capability;
            if (result && result.service === "luatools" && result.apiVersion === 1 && result.transport === "millennium") {
                if (old) old.dispose("Millennium backend available");
                return { transport: "millennium", version };
            }
        }
    } catch (_) { /* Missing LuaTools backend: the desktop bridge remains usable. */ }
    finally { clearTimeout(timer); }
    if (old && old.version === version && old.owner === window.Millennium && old.wrapper === window.Millennium.callServerMethod)
        return { transport: "cdp", version, nonce: old.nonce };
    if (old) old.dispose("Transport replaced");
    if (typeof window.__LuaToolsMacRPC !== "function") throw new Error("Native CDP binding missing");
    const pending = new Map();
    const nonce = crypto.randomUUID();
    let sequence = 0;
    const owner = window.Millennium || {};
    const prior = owner.callServerMethod;
    const state = {
        owner, version, nonce, nativeCall, wrapper: null,
        receive(reply) {
            if (!reply || reply.nonce !== nonce || !Number.isSafeInteger(reply.id)) return false;
            const entry = pending.get(reply.id);
            if (!entry) return false;
            pending.delete(reply.id); clearTimeout(entry.timer);
            if (reply.error) entry.reject(new Error(String(reply.error)));
            else entry.resolve(reply.result);
            return true;
        },
        dispose(reason) {
            for (const entry of pending.values()) { clearTimeout(entry.timer); entry.reject(new Error(reason)); }
            pending.clear();
            if (owner.callServerMethod === state.wrapper) {
                if (prior === undefined) delete owner.callServerMethod;
                else owner.callServerMethod = prior;
            }
            if (window.__LuaToolsMacTransport === state) delete window.__LuaToolsMacTransport;
        }
    };
    state.wrapper = function (plugin, method, args) {
        if (String(plugin).toLowerCase() !== "luatools") {
            return nativeCall ? nativeCall(plugin, method, args) : Promise.reject(new Error("Millennium backend unavailable"));
        }
        if (typeof method !== "string" || method.length > 128) return Promise.reject(new Error("Invalid RPC method"));
        if (pending.size >= 32) return Promise.reject(new Error("Too many LuaTools requests"));
        const id = ++sequence;
        return new Promise((resolve, reject) => {
            const timer = setTimeout(() => { pending.delete(id); reject(new Error("LuaTools RPC timed out")); }, 15000);
            pending.set(id, { resolve, reject, timer });
            try {
                const payload = JSON.stringify({ nonce, id, method, args: args == null ? {} : args });
                if (payload.length > 65536) throw new Error("LuaTools request too large");
                window.__LuaToolsMacRPC(payload);
            } catch (error) { clearTimeout(timer); pending.delete(id); reject(error); }
        });
    };
    owner.callServerMethod = state.wrapper;
    window.Millennium = owner;
    window.__LuaToolsMacTransport = state;
    return { transport: "cdp", version, nonce };
})()
