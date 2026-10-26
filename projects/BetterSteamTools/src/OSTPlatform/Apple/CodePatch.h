#pragma once
#include <cstdint>
#include <span>
#include <string>

namespace OSTPlatform::Apple {
// Replaces one executable page using a prepared RX copy. The live page is never
// made writable/non-executable. All ranges stay within a single page.
bool ReplaceCode(void* address, std::span<const uint8_t> expected, std::span<const uint8_t> replacement);
bool IsExecutable(const void* address);
bool IsWritable(const void* address);
std::string CodePatchLastError();
}
