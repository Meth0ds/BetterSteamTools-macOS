#include "MachOImageLayout.h"
#include <mach-o/loader.h>
#include <mach/vm_prot.h>
#include <cstring>
#include <limits>

namespace BST::Mac {
namespace {
template<class T> bool read(std::span<const uint8_t> bytes, size_t offset, T& value) {
    if (offset > bytes.size() || sizeof(T) > bytes.size() - offset) return false;
    std::memcpy(&value, bytes.data() + offset, sizeof(T)); return true;
}
bool contains(uint64_t base, uint64_t size, uint64_t address, uint64_t count) {
    return size <= UINT64_MAX - base && address >= base && address <= base + size && count <= base + size - address;
}
bool named(const char (&name)[16], const char* expected) { return std::strncmp(name, expected, sizeof name) == 0; }
}
std::optional<MachOImageLayout> MachOImageLayout::parse(std::span<const uint8_t> bytes) {
    mach_header_64 header{};
    if (!read(bytes, 0, header) || header.magic != MH_MAGIC_64 || header.cputype != CPU_TYPE_ARM64 ||
        header.filetype != MH_DYLIB || !header.ncmds || header.ncmds > 4096 || header.sizeofcmds > 1024 * 1024 ||
        header.sizeofcmds > bytes.size() - sizeof header) return std::nullopt;
    const size_t end = sizeof header + header.sizeofcmds;
    size_t offset = sizeof header;
    bool foundText = false, foundCode = false;
    MachOImageLayout result;
    for (uint32_t index = 0; index < header.ncmds; ++index) {
        load_command command{};
        if (offset > end || sizeof command > end - offset || !read(bytes, offset, command) ||
            command.cmdsize < sizeof command || command.cmdsize % 8 || command.cmdsize > end - offset) return std::nullopt;
        if (command.cmd == LC_SEGMENT_64) {
            segment_command_64 segment{};
            if (command.cmdsize < sizeof segment || !read(bytes, offset, segment) ||
                segment.nsects > (command.cmdsize - sizeof segment) / sizeof(section_64)) return std::nullopt;
            if (named(segment.segname, "__TEXT")) {
                if (foundText || !(segment.initprot & VM_PROT_EXECUTE) || !(segment.initprot & VM_PROT_READ) ||
                    (segment.initprot & VM_PROT_WRITE) || segment.vmsize > UINT64_MAX - segment.vmaddr) return std::nullopt;
                foundText = true; result.textVMAddress = segment.vmaddr; result.textVMSize = segment.vmsize;
                for (uint32_t sectionIndex = 0; sectionIndex < segment.nsects; ++sectionIndex) {
                    section_64 section{};
                    if (!read(bytes, offset + sizeof segment + sectionIndex * sizeof section, section)) return std::nullopt;
                    if (named(section.sectname, "__text")) {
                        if (foundCode || !named(section.segname, "__TEXT") || !(section.flags & S_ATTR_PURE_INSTRUCTIONS) ||
                            !section.size || !contains(segment.vmaddr, segment.vmsize, section.addr, section.size)) return std::nullopt;
                        foundCode = true; result.codeVMAddress = section.addr; result.codeVMSize = section.size;
                    }
                }
            }
        }
        offset += command.cmdsize;
    }
    if (offset != end || !foundText || !foundCode) return std::nullopt;
    return result;
}
std::optional<uintptr_t> MachOImageLayout::codeAddress(intptr_t slide, uint64_t rva, size_t length) const {
    if (!length || rva > UINT64_MAX - textVMAddress) return std::nullopt;
    const auto virtualAddress = textVMAddress + rva;
    if (!contains(codeVMAddress, codeVMSize, virtualAddress, length)) return std::nullopt;
    uint64_t address = virtualAddress;
    if (slide >= 0) {
        if (static_cast<uint64_t>(slide) > UINT64_MAX - address) return std::nullopt;
        address += static_cast<uint64_t>(slide);
    } else {
        const auto magnitude = uint64_t(-(slide + 1)) + 1;
        if (magnitude > address) return std::nullopt;
        address -= magnitude;
    }
    if (address > UINTPTR_MAX || length - 1 > UINTPTR_MAX - address) return std::nullopt;
    return static_cast<uintptr_t>(address);
}
}
