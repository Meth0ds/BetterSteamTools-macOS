#pragma once
#include <cstddef>
#include <cstdint>

extern "C" int32_t BSTVerifyBuildManifest(const char* manifestPath, const char* clientDirectory,
    const char* dylibPath, const char* keyID, const char* publicKeyHex, const char* expectedBuild,
    char* diagnostic, ptrdiff_t diagnosticCapacity);
