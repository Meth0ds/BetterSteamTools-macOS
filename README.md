# BetterSteamTools macOS

Port en desarrollo de BetterSteamTools y LuaTools para macOS 15+ en Apple Silicon, con integración de NotProton/CrossOver.

**Estado: desarrollo activo. No es una versión terminada ni una instalación lista para usar.** La paridad completa con Windows y las pruebas end-to-end dentro de Steam siguen pendientes. Este repositorio conserva el trabajo y permite revisar sus cambios.

## Proyectos

| Carpeta | Contenido | Origen |
| --- | --- | --- |
| `projects/BetterSteamTools` | Código original y backend nativo macOS; instalador, validación de builds y selección de compatibilidad | [madoiscool/BetterSteamTools](https://github.com/madoiscool/BetterSteamTools) |
| `projects/LuaTools` | Código original, cliente SwiftUI, servicio local y adaptación del plugin para macOS | [madoiscool/LuaTools](https://github.com/madoiscool/LuaTools) |

Los historiales de ambos proyectos se importan mediante Git subtree. Sus licencias y avisos originales permanecen en cada carpeta. `upstreams.lock.json` identifica los commits de partida y las dependencias investigadas. El trabajo específico del port se añade en commits separados.

[NotProton](https://github.com/NotProtonNot/NotProton) y CrossOver se detectan como dependencias externas. No se incluyen Steam, CrossOver, runners, juegos, licencias, datos de cuentas ni claves privadas.

## Validación y alcance

- [Estado y aceptación de BetterSteamTools](projects/BetterSteamTools/macos/IMPLEMENTATION_STATUS.md)
- [Estado y aceptación de LuaTools](projects/LuaTools/macos/IMPLEMENTATION_STATUS.md)
- [Manifiestos firmados de builds](projects/BetterSteamTools/macos/signatures/README.md)
- [Desarrollo y sincronización upstream](docs/DEVELOPMENT.md)
- [Procedencia y licencias](NOTICE.md)

Las pruebas locales verifican, entre otras cosas, parsers, selección de compatibilidad, transporte CDP, transacciones de instalación y recuperación tras terminar procesos. Un helper aislado ha aplicado y retirado un detour sobre el binario real de Steam instalado. Esto **no acredita todavía** el funcionamiento de todas las funciones dentro de Steam ni el lanzamiento de juegos. No hay builds de Steam aprobadas para una release; el almacén de confianza está vacío y la activación falla de forma cerrada.
