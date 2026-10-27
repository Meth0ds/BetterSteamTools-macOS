#pragma once
#include "MacConfiguration.h"
#include <optional>
#include <span>
#include <string_view>
namespace BST::Mac {
std::optional<uint32_t> DepotIDFromConfigKey(std::string_view name);
// Returns the number of bytes written, or zero when the original Steam path
// must run. Short buffers and unrelated config reads remain untouched.
size_t CopyConfiguredDepotKey(const ConfigurationSnapshot& snapshot, std::string_view name, std::span<uint8_t> output);
void** ConfigStoreOriginalSlot();
void* ConfigStoreReplacement();
}
