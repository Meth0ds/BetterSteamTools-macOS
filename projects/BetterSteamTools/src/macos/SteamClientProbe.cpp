#include "SteamClientProbe.h"
#include "MachOImageLayout.h"
#include "OSTPlatform/include/Hash.h"
#include "OSTPlatform/include/Memory.h"
#include "OSTPlatform/Apple/CodePatch.h"
#include <mach-o/dyld.h>
#include <dlfcn.h>
#include <array>
#include <cstring>

namespace BST::Mac {
std::optional<SteamClientProbe> probeSteamClient(std::string& diagnostic) {
    constexpr const char* approvedHash = "b9d62be2ac64b77dc77e1d19eefcf3880df99495c7db85b30623095310b6a6bd";
    constexpr uint64_t ownershipRVA = 0xa63738;
    constexpr std::array<uint8_t, 32> entryBytes = {
        0xff, 0x03, 0x04, 0xd1, 0xfc, 0x6f, 0x0a, 0xa9, 0xfa, 0x67, 0x0b, 0xa9, 0xf8, 0x5f, 0x0c, 0xa9,
        0xf6, 0x57, 0x0d, 0xa9, 0xf4, 0x4f, 0x0e, 0xa9, 0xfd, 0x7b, 0x0f, 0xa9, 0xfd, 0xc3, 0x03, 0x91
    };
    diagnostic = "steamclient.dylib is not loaded";
    for (uint32_t index = 0; index < _dyld_image_count(); ++index) {
        const char* raw = _dyld_get_image_name(index);
        if (!raw || std::filesystem::path(raw).filename() != "steamclient.dylib") continue;
        const std::filesystem::path path(raw);
        auto module = std::shared_ptr<void>(dlopen(path.c_str(), RTLD_NOLOAD | RTLD_NOW | RTLD_LOCAL), [](void* value) { if (value) dlclose(value); });
        if (!module) { diagnostic = "Cannot retain loaded steamclient.dylib"; return std::nullopt; }
        const auto* header = reinterpret_cast<const mach_header_64*>(_dyld_get_image_header(index));
        if (!header || !OSTPlatform::Memory::IsReadable(header, sizeof *header) || header->sizeofcmds > 1024 * 1024 ||
            !OSTPlatform::Memory::IsReadable(header, sizeof *header + header->sizeofcmds)) {
            diagnostic = "Invalid or unreadable Mach-O load commands"; return std::nullopt;
        }
        const auto layout = MachOImageLayout::parse({reinterpret_cast<const uint8_t*>(header), sizeof *header + header->sizeofcmds});
        const auto address = layout ? layout->codeAddress(_dyld_get_image_vmaddr_slide(index), ownershipRVA, entryBytes.size()) : std::nullopt;
        if (!address || !OSTPlatform::Apple::IsExecutable(reinterpret_cast<void*>(*address)) ||
            !OSTPlatform::Memory::IsReadable(reinterpret_cast<void*>(*address), entryBytes.size())) {
            diagnostic = "Ownership RVA is outside the readable executable __text section"; return std::nullopt;
        }
        if (OSTPlatform::Hash::Sha256OfFile(path) != approvedHash) {
            diagnostic = "Steam client SHA-256 is not reviewed for this hook module"; return std::nullopt;
        }
        if (std::memcmp(reinterpret_cast<void*>(*address), entryBytes.data(), entryBytes.size())) {
            diagnostic = "Ownership entry differs from reviewed ARM64 bytes; possible existing instrumentation"; return std::nullopt;
        }
        diagnostic = "Reviewed SHA-256, segment-relative RVA and 32 entry bytes match";
        return SteamClientProbe{path, *address, std::move(module)};
    }
    return std::nullopt;
}
}
