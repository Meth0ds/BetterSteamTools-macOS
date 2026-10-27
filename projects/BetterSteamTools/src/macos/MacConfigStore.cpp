#include "MacConfigStore.h"
#include "OSTPlatform/include/Memory.h"
#include "OSTPlatform/Apple/CodePatch.h"
#include <mach/mach.h>
#include <algorithm>
#include <atomic>
#include <charconv>
#include <cstring>

namespace BST::Mac {
std::optional<uint32_t> DepotIDFromConfigKey(std::string_view name) {
    if (name.empty() || name.size() > 4096 || name.find('\0') != std::string_view::npos) return std::nullopt;
    // The reviewed ARM64 call site formats precisely this full path. Do not
    // intercept another ConfigStore namespace just because its last fields
    // happen to be a depot number and "DecryptionKey".
    constexpr std::string_view prefix = "Software\\Valve\\Steam\\Depots\\";
    constexpr std::string_view suffix = "\\DecryptionKey";
    std::string normalized(name);
    std::replace(normalized.begin(), normalized.end(), '/', '\\');
    if (!normalized.starts_with(prefix) || !normalized.ends_with(suffix) ||
        normalized.size() <= prefix.size() + suffix.size()) return std::nullopt;
    const std::string_view digits(normalized.data() + prefix.size(), normalized.size() - prefix.size() - suffix.size());
    uint32_t id = 0;
    const auto [end, error] = std::from_chars(digits.data(), digits.data() + digits.size(), id);
    if (error != std::errc{} || end != digits.data() + digits.size() || id == 0) return std::nullopt;
    return id;
}
size_t CopyConfiguredDepotKey(const ConfigurationSnapshot& snapshot, std::string_view name, std::span<uint8_t> output) {
    const auto id = DepotIDFromConfigKey(name);
    if (!id) return 0;
    const auto found = snapshot.depots.find(*id);
    if (found == snapshot.depots.end() || found->second.size() != 32 || output.size() < found->second.size()) return 0;
    std::copy(found->second.begin(), found->second.end(), output.begin()); return found->second.size();
}
namespace {
void* original = nullptr;
using GetBinary = int32_t (*)(void*, uint32_t, const char*, void*, uint32_t);
std::optional<std::string_view> readableName(const char* name) {
    if (!name || reinterpret_cast<uintptr_t>(name) > UINTPTR_MAX - 4096) return std::nullopt;
    size_t offset = 0;
    while (offset < 4096) {
        const auto address = reinterpret_cast<uintptr_t>(name + offset);
        const auto count = std::min(size_t(4096 - offset), size_t(vm_page_size - address % vm_page_size));
        if (!OSTPlatform::Memory::IsReadable(name + offset, count)) return std::nullopt;
        const auto* end = static_cast<const char*>(std::memchr(name + offset, 0, count));
        if (end) return std::string_view(name, static_cast<size_t>(end - name));
        offset += count;
    }
    return std::nullopt;
}
int32_t getBinary(void* object, uint32_t store, const char* name, void* output, uint32_t capacity) {
    const auto next = reinterpret_cast<GetBinary>(std::atomic_ref<void*>(original).load(std::memory_order_acquire));
    const auto snapshot = GetConfigurationSnapshot();
    if (object && store == 1 && snapshot && !snapshot->depots.empty() && output && capacity >= 32 &&
        reinterpret_cast<uintptr_t>(output) <= UINTPTR_MAX - 31 &&
        OSTPlatform::Memory::IsReadable(output, 32) && OSTPlatform::Apple::IsWritable(output) &&
        OSTPlatform::Apple::IsWritable(static_cast<uint8_t*>(output) + 31)) {
        const auto key = readableName(name);
        if (key) {
            const auto count = CopyConfiguredDepotKey(*snapshot, *key, {static_cast<uint8_t*>(output), 32});
            if (count) return static_cast<int32_t>(count);
        }
    }
    return next ? next(object, store, name, output, capacity) : 0;
}
}
void** ConfigStoreOriginalSlot() { return &original; }
void* ConfigStoreReplacement() { return reinterpret_cast<void*>(getBinary); }
}
