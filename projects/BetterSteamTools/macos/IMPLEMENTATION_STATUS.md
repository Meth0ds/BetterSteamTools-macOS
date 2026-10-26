# Implementation and acceptance ledger

This file records evidence for the requested full macOS port. A successful build is not evidence of feature parity. The release gate remains open until every required row has runtime evidence.

## Verified in the current checkout

| Requirement | Evidence | Boundary |
| --- | --- | --- |
| Separate Apple CMake target | CMake/Ninja builds `BetterSteamTools.dylib`; `file` reports arm64 Mach-O | Most Steam hook families and in-client acceptance remain pending |
| Native platform foundations | `bst-platform-selftest` passes CTest with local HTTP, dyld text lookup, Mach VM readability, libproc/sysctl process queries and real FSEvents create/modify/remove notifications | Native pre-call instrumentation, foreign-task inspection and Keychain remain pending |
| ARM64 entry redirects | Debug and Release `bst-detour-selftest`: executable-page replacement, one-instruction redirects, ADR/ADRP/integer literal/conditional relocation, stack/PAC prologues, restoration, failed batch preflight, later foreign patch preservation and live concurrent calls | Independent engine tests, not Steam ABI approval; B/BL/register-branch entries and SIMD literal entries are deliberately rejected. No third-party hook chaining. Retired trampolines remain mapped with bounded allocation. Multi-hook batches validate before applying and attempt rollback on an application failure; they do not provide simultaneous visibility across all functions. |
| Real Steam 1792618285 code-patching smoke | `bst-real-hook-smoke` loads the installed arm64 `steamclient.dylib` in an auxiliary process, verifies its SHA-256, segment-relative RVA and 32 original entry bytes, attaches a pass-through detour, detaches it and checks exact byte restoration. Native layout tests reject section/segment confusion, bad commands, overflow and non-code RVAs. | No real Steam user object or ownership function call is exercised. In-client ABI, NotProton coexistence, library behavior and game launch remain unproved. The runtime's Lua AppID scanner is still a temporary regex implementation, not Lua feature parity. |
| Valve text configuration | KeyValues self-tests cover nesting, escaping, comments, duplicate ambiguity, targeted replacement | Binary appinfo is not implemented yet |
| Native / Windows classification | Self-tests cover real header fields, 64/32 bit distinctions, Mach-O library false positives, PE headers, malformed files | Not validated on the full game fixture matrix or live Steam |
| Routing selection affects Steam config | Self-test checks native sentinel and per-app CrossOver name under CompatToolMapping and leaves the global mapping intact. Live NotProton is recognized from its local tools registry, installed dylib, executable shim and CrossOver runner. Tests cover minimal layouts, valid optional declarations, malformed/mismatched declarations and missing runners. | The tools registry has no cryptographic signature. Live Steam mutations require its runtime interface; current writes require Steam closed. |
| Transactional bundle activation | Full app snapshot, staged signing plus strict codesign verification, atomic bundle swap, private per-bundle lock, journal and owned payload/approval receipt. Child-process tests exit at five checkpoints during install and uninstall, then verify recovery and exact executable/signature/resource restoration. A real codesign fixture installs the native dylib and restores its original signed bundle. Later external changes cause recovery conflicts instead of being overwritten. | The user's live Steam bundle has not been deployed. Automatic Steam shutdown, complete updater UI and the live deployment matrix remain pending. |
| Authenticated build manifest | Installer and native C ABI use the same CryptoKit Ed25519 verifier. Runtime verifies all three inner client files and the dylib against its compiled trust root before attaching a hook. Tests cover altered signed bytes, unknown/empty keys, changed dylib/client files, wrong build and diagnostic buffer bounds. | Release trust store is empty; no actual Steam build approved. The isolated code-patching helper does not claim release approval. |
| LuaTools loopback and plugin transports | HTTP/TCP tests; real loopback WebSocket CDP tests with fragmented/out-of-order replies, notifications, timeout/cancel/disconnect, origin/context/nonce gating, navigation and reconnect; JavaScript Millennium handshake/coexistence tests | Service feature parity and live Steam/Millennium acceptance remain pending |

## Exact-build investigation

Valve's stable macOS build 1792618285 has been downloaded into workspace-only fixtures. All three archives were checked against the SHA-256 values in Valve's HTTPS manifest. The universal binaries contain arm64 slices. `tools/macos/resolve_anchors.py` locates LC_FUNCTION_STARTS-bounded candidates through exact adjacent ADRP/ADD string references. Its tests build a real arm64 fixture and verify unique, absent, ambiguous and truncated cases. Four unique candidate functions are recorded in `signatures/analysis/1792618285-steamclient.analysis.json`. This is analysis only, not a signed runtime approval or a claim that the hooks work.

## Release-blocking work

- Implement and validate every original BetterSteamTools hook family for macOS arm64; bootstrap does not implement unlock, ticket, depot, IPC, UI or game-process hooks.
- Discover function signatures against exact Steam binaries, publish authenticated manifests and prove coexistence with NotProton.
- Complete the native OS backend and replace Windows-only host assumptions in the shared core.
- Complete LuaTools feature/UI parity, persistent settings, source/download workflows, Lua build editor, manifests, fixes, update/rollback and dependency diagnostics.
- Complete plugin service RPC features, safe external URL handling, automatic app lifecycle and authenticated plugin upgrade/uninstall; prove the implemented Millennium/CDP bridge inside live Steam.
- Produce and verify app bundles, DMG/ZIP packaging, license notices, reproducible CI artifacts and conditional signing/notarization.
- Run end-to-end acceptance with Steam, a native game and a Windows game through a licensed supported CrossOver runner.

No user Steam bundle has been modified by these tests. Mutation and signing tests use temporary app/configuration fixtures. The current machine has native Steam build 1792618285, NotProton 1.2.1 and a detected CrossOver 26.3 runner. The auxiliary smoke modifies only its own process mappings. No native/Windows game launch or Steam plugin UI acceptance has been proved.
