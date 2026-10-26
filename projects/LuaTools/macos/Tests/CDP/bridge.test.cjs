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
        if (plugin === 'luatools') return Promise.resolve(JSON.stringify({ service: 'luatools', apiVersion: 1, transport: 'millennium' }));
        return Promise.resolve('native:' + method);
    } };
    const nativeFn = native.callServerMethod;
    const millennium = realm(undefined, native);
    try {
        const handshake = await millennium.run();
        assert.equal(handshake.transport, 'cdp');
        assert.equal(handshake.loader, 'lualoader-macos');
        assert.equal(nativeCalls.length, 0, 'LuaLoader does not probe or delegate LuaTools RPC to Millennium');
        const pending = native.callServerMethod('luatools', 'GetThemes', {});
        assert.equal(millennium.calls.length, 1);
        millennium.context.__LuaToolsMacTransport.receive({ nonce: handshake.nonce, id: 1, result: 'LuaLoader reply' });
        assert.equal(await pending, 'LuaLoader reply');
        assert.equal(nativeCalls.length, 0);
        const args = { setting: 'example' };
        assert.equal(await native.callServerMethod('another-plugin', 'ReadSettings', args), 'native:ReadSettings');
        assert.equal(nativeCalls[0].args, args, 'unrelated plugin arguments and receiver survive');
        millennium.context.__LuaToolsMacTransport.dispose('Test done');
        assert.equal(native.callServerMethod, nativeFn, 'disposal restores exact original API');
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
        const initial = await coexist.run();
        assert.equal(initial.transport, 'cdp');
        assert.equal(await otherPlugin.callServerMethod('some-other-plugin', 'ReadSettings', {}), 'other:ReadSettings');
        const pending = otherPlugin.callServerMethod('luatools', 'GetThemes', {});
        const wrapper = otherPlugin.callServerMethod;
        backendAvailable = true;
        const repeated = await coexist.run();
        assert.equal(repeated.nonce, initial.nonce, 'late Millennium activation does not replace LuaLoader');
        assert.equal(otherPlugin.callServerMethod, wrapper, 'one LuaTools wrapper remains installed');
        coexist.context.__LuaToolsMacTransport.receive({ nonce: initial.nonce, id: 1, result: 'pending survives' });
        assert.equal(await pending, 'pending survives');
        coexist.context.__LuaToolsMacTransport.dispose('Test done');
        assert.equal(otherPlugin.callServerMethod, original);
    } finally { coexist.close(); }
    console.log('PASS: LuaLoader priority, RPC correlation, nonce isolation, errors, disposal and Millennium coexistence');
})().catch(error => { console.error(error); process.exitCode = 1; });
