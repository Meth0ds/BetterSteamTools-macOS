# Desarrollo

## Estructura e historial

BetterSteamTools y LuaTools se importan como subtrees con sus historiales originales completos. Los commits de importación fijan la base y los siguientes contienen el port. Los repositorios upstream permanecen como remotos de lectura; `origin` apunta al monorepo.

Para incorporar upstream, usa una rama de trabajo, revisa el diff y actualiza el lockfile después de resolver y probar la integración:

```sh
git fetch upstream-bst
git subtree merge --prefix=projects/BetterSteamTools upstream-bst/main
git fetch upstream-luatools
git subtree merge --prefix=projects/LuaTools upstream-luatools/main
```

Comprueba la rama upstream efectiva antes de ejecutar esos ejemplos. No mezcles ni sustituyas los dos subtrees. El código original Windows permanece dentro de cada proyecto y conserva sus instrucciones de build.

## BetterSteamTools en macOS arm64

```sh
cd projects/BetterSteamTools
swift build --package-path macos
swift run --package-path macos bst-macos-selftest
cmake -S src -B build-macos -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build-macos
ctest --test-dir build-macos/macos --output-on-failure
swift run --package-path macos bst-macos-selftest --codesign-dylib "$PWD/build-macos/macos/BetterSteamTools.dylib"
```

La última prueba firma una app temporal y comprueba la instalación, recuperación y restauración; no despliega BetterSteamTools en el Steam del usuario. Las pruebas generan claves efímeras para sus fixtures, nunca claves privadas de release.

`bst-real-hook-smoke` es una herramienta de desarrollo aislada que requiere una copia real del cliente con SHA-256 conocido. No distribuyas esos binarios ni conviertas un resultado de esa herramienta en aprobación de una release.

## LuaTools en macOS arm64

```sh
cd projects/LuaTools
swift build --package-path macos
swift run --package-path macos LuaToolsMacSelfTest
node macos/Tests/CDP/bridge.test.cjs
```

La CI añade el servidor WebSocket falso y las pruebas Lua del plugin. Consulta los workflows y los documentos de estado de cada proyecto para los límites de la cobertura actual.

## Guardar cambios

Haz commits pequeños que expliquen el comportamiento y su validación, y súbelos a `origin`. Mantén los datos de Steam, archivos personales, claves y dependencias comerciales fuera del árbol. Los documentos de aceptación distinguen pruebas locales de aceptación dentro de Steam; actualízalos con evidencia al avanzar.
