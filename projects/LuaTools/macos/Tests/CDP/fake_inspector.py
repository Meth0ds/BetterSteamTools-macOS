#!/usr/bin/env python3
"""Run the native CDP contract tests against a real loopback WebSocket peer.

The fixture deliberately interleaves notifications, fragments replies, closes sockets,
and answers concurrent requests in reverse order. JavaScript semantics are tested
separately by bridge.test.cjs; this peer implements the wire contract, not Chromium.
Usage: python fake_inspector.py -- <path-to-LuaToolsCDPSelfTest>
"""
import asyncio
import json
import re
import sys
from http import HTTPStatus
from urllib.parse import urlsplit

from websockets.asyncio.server import serve
from websockets.datastructures import Headers
from websockets.http11 import Response
from websockets.exceptions import ConnectionClosed


class Fixture:
    def __init__(self):
        self.port = None
        self.mode = "cdp"
        self.context = 7
        self.nonce = "fixture-nonce-7"
        self.frontend_digest = None
        self.sockets = set()
        self.stats = {"connections": 0, "frontends": 0, "replies": [], "handshakes": 0}

    async def http(self, connection, request):
        path = urlsplit(request.path).path
        if path.startswith("/ws/"):
            return None
        if path == "/json":
            def tab(identifier, url, ws=None):
                return {"id": identifier, "type": "page", "url": url,
                        "webSocketDebuggerUrl": ws or f"ws://127.0.0.1:{self.port}/ws/{identifier}"}
            result = [tab("store", "https://store.steampowered.com/app/42/"),
                      tab("foreign", "https://store.steampowered.com.evil.test/"),
                      tab("userinfo", "https://store.steampowered.com@evil.test/"),
                      tab("socket-foreign", "https://store.steampowered.com/", "ws://example.com:8080/ws/bad"),
                      tab("socket-port", "https://store.steampowered.com/", "ws://127.0.0.1:1/ws/bad")]
        elif path == "/stats":
            result = self.stats
        elif path.startswith("/control/"):
            action = path.split("/")[-1]
            if action == "navigate":
                self.context += 1
                self.nonce = f"fixture-nonce-{self.context}"
                self.frontend_digest = None
                for socket in list(self.sockets):
                    await socket.send(json.dumps({"method": "Runtime.executionContextsCleared", "params": {}}))
                    await self.contexts(socket)
            elif action == "disconnect":
                for socket in list(self.sockets):
                    await socket.close()
            else:
                self.mode = action
            result = {"success": True}
        else:
            return Response(HTTPStatus.NOT_FOUND, "Not Found", Headers(), b"")
        body = json.dumps(result).encode()
        return Response(HTTPStatus.OK, "OK", Headers({"Content-Type": "application/json", "Content-Length": str(len(body))}), body)

    async def contexts(self, socket):
        for identifier, origin, default in [(self.context, "https://store.steampowered.com", True),
                                             (700, "https://example.com", True),
                                             (701, "https://store.steampowered.com", False)]:
            await socket.send(json.dumps({"method": "Runtime.executionContextCreated", "params": {
                "context": {"id": identifier, "origin": origin, "auxData": {"isDefault": default}}}}))

    async def bindings(self, socket):
        await asyncio.sleep(0.03)
        base = {"nonce": self.nonce, "id": 1, "method": "HasLuaToolsForApp", "args": {"appid": 42}}
        for context, payload in [(self.context, base), (self.context, base), (700, {**base, "id": 2}), (701, {**base, "id": 3}),
                                 (self.context, {**base, "id": 4, "nonce": "stale-document"})]:
            try:
                await socket.send(json.dumps({"method": "Runtime.bindingCalled", "params": {
                    "name": "__LuaToolsMacRPC", "executionContextId": context, "payload": json.dumps(payload)}}))
            except ConnectionClosed:
                return

    async def message(self, socket, request):
        identifier, method = request["id"], request["method"]
        params = request.get("params", {})
        if method == "Fixture.wait":
            return
        if method == "Fixture.disconnect":
            await socket.close()
            return
        if method == "Fixture.remoteError":
            await socket.send(json.dumps({"id": identifier, "error": {"code": -32000, "message": "fixture rejection"}}))
            return
        if method == "Fixture.echo":
            await asyncio.sleep(params.get("delay", 0))
            result = {"echo": params["value"]}
        elif method == "Runtime.enable":
            await self.contexts(socket)
            result = {}
        elif method == "Runtime.addBinding":
            assert params["name"] == "__LuaToolsMacRPC"
            result = {}
        elif method == "Runtime.evaluate":
            expression = params["expression"]
            if expression == "fixture.throw":
                result = {"exceptionDetails": {"text": "fixture JavaScript exception"}, "result": {"type": "undefined"}}
            elif "Native CDP transport only" in expression:
                self.stats["handshakes"] += 1
                value = {"transport": "millennium", "version": 2} if self.mode == "legacy-handshake" else {"transport": "cdp", "loader": "lualoader-macos", "version": 2, "nonce": self.nonce}
                result = {"result": {"value": value}}
            elif expression.startswith("Boolean(window.__LuaToolsMacTransport?.receive("):
                payload = json.loads(expression[len("Boolean(window.__LuaToolsMacTransport?.receive("):-2])
                self.stats["replies"].append({"context": params.get("contextId"), **payload})
                result = {"result": {"value": True}}
            elif "__fixtureFrontend" in expression:
                wanted = re.search(r"const wanted='([0-9a-f]{64})'", expression)
                assert wanted, "frontend digest missing"
                if self.mode != "broken" and self.frontend_digest is None:
                    self.frontend_digest = wanted.group(1)
                    self.stats["frontends"] += 1
                result = {"result": {"value": {"installed": self.mode != "broken", "digest": self.frontend_digest or ""}}}
                if self.mode == "cdp" and self.frontend_digest == wanted.group(1):
                    asyncio.create_task(self.bindings(socket))
            else:
                raise AssertionError(f"unexpected evaluation: {expression[:100]}")
        else:
            raise AssertionError(f"unexpected method: {method}")
        # Notifications must not satisfy a pending command; fragmented responses must be reassembled.
        await socket.send(json.dumps({"method": "Fixture.notification", "params": {"request": identifier}}))
        encoded = json.dumps({"id": identifier, "result": result})
        await socket.send([encoded[:len(encoded) // 2], encoded[len(encoded) // 2:]])

    async def websocket(self, socket):
        self.sockets.add(socket)
        self.stats["connections"] += 1
        tasks = set()
        try:
            async for raw in socket:
                task = asyncio.create_task(self.message(socket, json.loads(raw)))
                tasks.add(task)
            await asyncio.gather(*tasks)
        except ConnectionClosed:
            pass
        finally:
            self.sockets.discard(socket)
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)


async def main():
    command = sys.argv[1:]
    if command and command[0] == "--":
        command.pop(0)
    if not command:
        raise SystemExit(__doc__)
    fixture = Fixture()
    async with serve(fixture.websocket, "127.0.0.1", 0, process_request=fixture.http, max_size=2_097_152) as server:
        fixture.port = server.sockets[0].getsockname()[1]
        process = await asyncio.create_subprocess_exec(*command, f"http://127.0.0.1:{fixture.port}")
        try:
            result = await asyncio.wait_for(process.wait(), timeout=40)
        except asyncio.TimeoutError:
            process.kill()
            await process.wait()
            raise SystemExit("CDP native tests exceeded their deadline")
        raise SystemExit(result)


if __name__ == "__main__":
    asyncio.run(main())
