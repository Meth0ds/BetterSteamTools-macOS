const { readFileSync } = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');
const path = require('node:path');
const source = readFileSync(path.join(__dirname, '../../Sources/LuaToolsMacCore/Resources/CDPBridge.js'), 'utf8');

function realm(origin = 'https://store.steampowered.com', millennium) {
    const calls = [], timers = new Set();
    const context = vm.createContext({ location: { origin }, crypto: { randomUUID },
        setTimeout(callback, delay) { const timer = setTimeout(callback, delay); timers.add(timer); return timer; },
        clearTimeout(timer) { timers.delete(timer); clearTimeout(timer); } });
    context.window = context;
    context.__LuaToolsMacRPC = payload => calls.push(JSON.parse(payload));
    if (millennium) context.Millennium = millennium;
    return { context, calls, run: () => vm.runInContext(source, context),
        close() { for (const timer of timers) clearTimeout(timer); } };
}

(async () => {
    const foreign = realm('https://store.steampowered.com.evil.test');
    assert.equal((await foreign.run()).transport, 'excluded');
    assert.equal(foreign.context.Millennium, undefined);

    const fallback = realm();
    try {
        const handshake = await fallback.run();
        assert.equal(handshake.transport, 'cdp');
        assert.equal(fallback.context.__LuaToolsReady, undefined, 'transport must not claim UI readiness');
        const first = fallback.context.Millennium.callServerMethod('luatools', 'HasLuaToolsForApp', { appid: 42 });
        const second = fallback.context.Millennium.callServerMethod('luatools', 'GetThemes', {});
        const state = fallback.context.__LuaToolsMacTransport;
        assert.equal((await fallback.run()).nonce, handshake.nonce, 'repeated handshake preserves pending promises');
        assert.equal(fallback.calls.length, 2);
        assert.equal(state.receive({ nonce: 'other-document', id: 2, result: 'wrong' }), false);
        assert.equal(state.receive({ nonce: handshake.nonce, id: 2, result: 'second' }), true);
        assert.equal(await second, 'second');
        assert.equal(state.receive({ nonce: handshake.nonce, id: 1, result: 'first' }), true);
        assert.equal(await first, 'first');
        assert.equal(state.receive({ nonce: handshake.nonce, id: 1, result: 'duplicate' }), false);
        const failure = fallback.context.Millennium.callServerMethod('luatools', 'Unknown', {});
        state.receive({ nonce: handshake.nonce, id: 3, error: 'No such method' });
        await assert.rejects(failure, /No such method/);
        const circular = {}; circular.self = circular;
        await assert.rejects(fallback.context.Millennium.callServerMethod('luatools', 'Test', circular), /circular/i);
        const outstanding = fallback.context.Millennium.callServerMethod('luatools', 'Test', {});
        state.dispose('Document closed');
        await assert.rejects(outstanding, /Document closed/);
        assert.equal(fallback.context.Millennium.callServerMethod, undefined);
    } finally { fallback.close(); }

    const nativeCalls = [];
    const native = { callServerMethod(plugin, method, args) {
        assert.equal(this, native);
        nativeCalls.push({ plugin, method, args });
        if (plugin === 'luatools' && method === 'GetCapabilities') return Promise.resolve(JSON.stringify({ service: 'luatools', apiVersion: 1, transport: 'millennium' }));
        return Promise.resolve('native');
    } };
    const nativeFn = native.callServerMethod;
    const millennium = realm(undefined, native);
    try {
        assert.equal((await millennium.run()).transport, 'millennium');
        assert.equal(native.callServerMethod, nativeFn, 'a live native backend is never wrapped');
        assert.equal(millennium.context.__LuaToolsMacTransport, undefined);
    } finally { millennium.close(); }

    let backendAvailable = false;
    const otherPlugin = { callServerMethod(plugin, method) {
        assert.equal(this, otherPlugin);
        if (plugin === 'luatools') {
            if (backendAvailable) return Promise.resolve({ service: 'luatools', apiVersion: 1, transport: 'millennium' });
            return Promise.reject(new Error('Plugin missing'));
        }
        return Promise.resolve('other:' + method);
    } };
    const original = otherPlugin.callServerMethod;
    const coexist = realm(undefined, otherPlugin);
    try {
        assert.equal((await coexist.run()).transport, 'cdp');
        assert.equal(await otherPlugin.callServerMethod('some-other-plugin', 'ReadSettings', {}), 'other:ReadSettings');
        const pending = otherPlugin.callServerMethod('luatools', 'GetThemes', {});
        const rejection = assert.rejects(pending, /Millennium backend available/);
        backendAvailable = true;
        assert.equal((await coexist.run()).transport, 'millennium');
        await rejection;
        assert.equal(otherPlugin.callServerMethod, original, 'late native activation restores exact original function');
    } finally { coexist.close(); }
    console.log('PASS: bridge RPC correlation, nonce isolation, errors, disposal, Millennium preference and coexistence');
})().catch(error => { console.error(error); process.exitCode = 1; });
