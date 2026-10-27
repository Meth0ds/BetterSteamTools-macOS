#include "../SteamClientProbe.h"
#include "OSTPlatform/include/Memory.h"
#include "OSTPlatform/Apple/CodePatch.h"
#include <mach-o/loader.h>
#include <dlfcn.h>
#include <array>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <optional>
#include <set>
#include <sstream>
#include <stdexcept>
#include <vector>

struct Region { uintptr_t address; size_t size; };
static void check(bool condition, const char* message) { if (!condition) throw std::runtime_error(message); }
static uint64_t word(uintptr_t address) { uint64_t value; std::memcpy(&value, reinterpret_cast<void*>(address), sizeof value); return value; }
static std::string hex(uintptr_t value) { std::ostringstream out; out << "0x" << std::hex << value; return out.str(); }
static std::string bytes(uintptr_t address, size_t count) {
    std::ostringstream out; out << std::hex << std::setfill('0');
    const auto* data = reinterpret_cast<const uint8_t*>(address);
    for (size_t index = 0; index < count; ++index) out << std::setw(2) << static_cast<unsigned>(data[index]);
    return out.str();
}
int main(int argc, char** argv) {
    try {
        check(argc == 2, "usage: bst-steam-rtti-probe <reviewed steamclient.dylib>");
        const auto handle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
        if (!handle) throw std::runtime_error(dlerror() ?: "dlopen failed");
        std::string diagnostic;
        const auto image = BST::Mac::probeSteamClient(diagnostic);
        if (!image) throw std::runtime_error(diagnostic);
        Dl_info info{}; check(dladdr(reinterpret_cast<void*>(image->ownershipEntry), &info) && info.dli_fbase, "loaded image header");
        const auto* header = static_cast<const mach_header_64*>(info.dli_fbase);
        check(header->sizeofcmds <= 1024 * 1024 && OSTPlatform::Memory::IsReadable(header, sizeof *header + header->sizeofcmds), "bounded readable load commands");
        const auto base = reinterpret_cast<uintptr_t>(header);
        const auto commandsEnd = base + sizeof *header + header->sizeofcmds;
        uintptr_t cursor = base + sizeof *header;
        std::vector<Region> constants, strings;
        std::optional<intptr_t> slide;
        for (uint32_t index = 0; index < header->ncmds; ++index) {
            check(cursor <= commandsEnd - sizeof(load_command), "load command bounds");
            const auto* command = reinterpret_cast<const load_command*>(cursor);
            check(command->cmdsize >= sizeof *command && command->cmdsize <= commandsEnd - cursor, "load command size");
            if (command->cmd == LC_SEGMENT_64) {
                const auto* segment = reinterpret_cast<const segment_command_64*>(cursor);
                check(command->cmdsize >= sizeof *segment && segment->nsects <= (command->cmdsize - sizeof *segment) / sizeof(section_64), "section table bounds");
                if (!std::strncmp(segment->segname, "__TEXT", 16)) {
                    check(segment->fileoff == 0, "header must begin in __TEXT");
                    slide = static_cast<intptr_t>(base - segment->vmaddr);
                }
                check(slide.has_value(), "__TEXT must precede data segments");
                const auto* sections = reinterpret_cast<const section_64*>(segment + 1);
                for (uint32_t number = 0; number < segment->nsects; ++number) {
                    const auto& section = sections[number];
                    const auto address = static_cast<uintptr_t>(section.addr + *slide);
                    if (!section.size || !OSTPlatform::Memory::IsReadable(reinterpret_cast<void*>(address), section.size)) continue;
                    if (!std::strncmp(section.sectname, "__cstring", 16) ||
                        (!std::strncmp(segment->segname, "__TEXT", 16) && !std::strncmp(section.sectname, "__const", 16))) strings.push_back({address, section.size});
                    if ((!std::strncmp(segment->segname, "__DATA_CONST", 16) || !std::strncmp(segment->segname, "__DATA", 16)) &&
                        (!std::strncmp(section.sectname, "__const", 16) || !std::strncmp(section.sectname, "__data", 16))) constants.push_back({address, section.size});
                }
            }
            cursor += command->cmdsize;
        }
        check(cursor == commandsEnd && !constants.empty(), "complete image data inventory");
        constexpr char name[] = "12CConfigStore";
        std::set<uintptr_t> names, types, vtables;
        for (const auto& range : strings) {
            const auto* text = reinterpret_cast<const char*>(range.address);
            for (size_t index = 0; index + sizeof name <= range.size; ++index)
                if (!std::memcmp(text + index, name, sizeof name)) names.insert(range.address + index);
        }
        for (const auto& range : constants) {
            for (size_t offset = 8; offset + 8 <= range.size; offset += 8) {
                const auto address = range.address + offset;
                if (names.contains(word(address))) {
                    Dl_info rtti{};
                    if (dladdr(reinterpret_cast<void*>(word(address - 8)), &rtti) && rtti.dli_sname &&
                        std::strstr(rtti.dli_sname, "class_type_info")) types.insert(address - 8);
                }
            }
        }
        for (const auto& range : constants) {
            for (size_t offset = 8; offset + 8 + 15 * 8 <= range.size; offset += 8) {
                const auto address = range.address + offset;
                if (types.contains(word(address)) && word(address - 8) == 0) vtables.insert(address + 8);
            }
        }
        if (names.size() != 1 || types.size() != 1 || vtables.size() != 1)
            throw std::runtime_error("RTTI primary-vtable inventory is ambiguous or incomplete: names=" + std::to_string(names.size()) + " types=" + std::to_string(types.size()) + " tables=" + std::to_string(vtables.size()));
        const auto table = *vtables.begin();
        // Reviewed call sites a6e41c/a6e4e8 call the primary CConfigStore
        // interface at +0x30 (GetBinary) / +0x70 (SetBinary), respectively.
        std::cout << "{\"format\":\"analysis-only\",\"runtimeApproved\":false,\"class\":\"CConfigStore\",\"vtableRVA\":\"" << hex(table - base) << "\",\"methods\":[";
        bool first = true;
        for (const auto& method : std::array<std::pair<const char*, size_t>, 2>{{{"GetBinary", 6}, {"SetBinary", 14}}}) {
            const auto function = word(table + method.second * 8);
            check(function >= base && OSTPlatform::Apple::IsExecutable(reinterpret_cast<void*>(function)) &&
                  OSTPlatform::Memory::IsReadable(reinterpret_cast<void*>(function), 32), "method must be executable and readable");
            Dl_info target{}; check(dladdr(reinterpret_cast<void*>(function), &target) && target.dli_fbase == info.dli_fbase, "method must belong to reviewed steamclient");
            if (!first) std::cout << ','; first = false;
            std::cout << "{\"name\":\"" << method.first << "\",\"slot\":" << method.second << ",\"functionRVA\":\"" << hex(function - base) << "\",\"entryBytes\":\"" << bytes(function, 32) << "\"}";
        }
        std::cout << "]}\n";
        return 0;
    } catch (const std::exception& error) { std::cerr << "FAIL: " << error.what() << '\n'; return 1; }
}
