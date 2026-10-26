#pragma once
#include <cstdint>
#include <optional>
#include <span>

namespace BST::Mac {
// Addresses in build manifests are RVAs from the __TEXT segment, not offsets
// from the __text section. Parse only the supplied, bounded load-command bytes.
struct MachOImageLayout {
    uint64_t textVMAddress = 0;
    uint64_t textVMSize = 0;
    uint64_t codeVMAddress = 0;
    uint64_t codeVMSize = 0;
    static std::optional<MachOImageLayout> parse(std::span<const uint8_t> bytes);
    std::optional<uintptr_t> codeAddress(intptr_t slide, uint64_t rva, size_t length) const;
};
}
