# BetterSteamTools macOS

Esta implementación arm64 separa la integración de Steam macOS del backend Win32. El paquete Swift proporciona:

- detección de bibliotecas y appmanifests;
- clasificación Mach-O/`.app` frente a `.exe`;
- routing automático nativo macOS o NotProton/CrossOver;
- overrides persistentes por AppID;
- diagnóstico de NotProton y CrossOver;
- activación reversible conservando `DYLD_INSERT_LIBRARIES`;
- validación SHA-256 de una build de Steam mediante manifiesto.

El target CMake `BetterSteamToolsMac` es un bootstrap dylib fail-closed. No activa hooks de Steam para builds sin firma publicada: cada módulo de hooks debe llegar acompañado de una firma y pruebas para la build exacta de Steam.
