#include "Arm64Relocator.h"
#include <limits>

namespace OSTPlatform::Apple::Arm64 {
namespace {
int64_t SignExtend(uint64_t value, unsigned bits) {
    const uint64_t sign = uint64_t{1} << (bits - 1);
    return static_cast<int64_t>((value ^ sign) - sign);
}
void Materialize(std::vector<uint32_t>& output, unsigned reg, uint64_t value) {
    output.push_back(0xD2800000u | ((value & 0xffff) << 5) | reg); // MOVZ Xd, imm16
    for (unsigned part = 1; part < 4; ++part) {
        output.push_back(0xF2800000u | (part << 21) | (((value >> (16 * part)) & 0xffff) << 5) | reg);
    }
}
}
std::optional<uint32_t> Branch(uintptr_t from, uintptr_t to) {
    if ((from | to) & 3) return std::nullopt;
    // User-space Mach-O addresses fit in signed 64-bit virtual address space.
    if (from > INT64_MAX || to > INT64_MAX) return std::nullopt;
    const auto delta = static_cast<int64_t>(to) - static_cast<int64_t>(from);
    if (delta < -(int64_t{1} << 27) || delta >= (int64_t{1} << 27)) return std::nullopt;
    return 0x14000000u | (static_cast<uint32_t>(delta / 4) & 0x03ffffffu);
}
std::optional<std::vector<uint32_t>> RelocateEntry(uint32_t instruction, uintptr_t from, uintptr_t to) {
    if ((from | to) & 3 || from > INT64_MAX - 4 || to > INT64_MAX - 32) return std::nullopt;
    std::vector<uint32_t> output;
    if ((instruction & 0x7C000000u) == 0x14000000u || (instruction & 0xFE000000u) == 0xD6000000u ||
        (instruction & 0xFF000000u) == 0xD4000000u || instruction == 0) {
        // B/BL and register branches can be a pre-existing third-party redirect.
        // No implicit chaining, and no exception-generating entry instructions.
        return std::nullopt;
    } else if ((instruction & 0x1F000000u) == 0x10000000u) {
        const uint64_t immediate = ((instruction >> 29) & 3) | (uint64_t((instruction >> 5) & 0x7ffff) << 2);
        const auto displacement = SignExtend(immediate, 21);
        const bool page = (instruction >> 31) != 0;
        const auto base = page ? (from & ~uintptr_t{0xfff}) : from;
        const auto value = static_cast<uint64_t>(base) + displacement * (page ? 4096 : 1);
        const auto reg = instruction & 31;
        if (reg == 31) return std::nullopt;
        Materialize(output, reg, value);
    } else if ((instruction & 0x3B000000u) == 0x18000000u) {
        const auto reg = instruction & 31;
        const auto opcode = instruction >> 30;
        if ((instruction & (1u << 26)) || opcode == 3 || reg == 31) return std::nullopt; // SIMD, PRFM, XZR need scratch state
        const auto address = static_cast<uint64_t>(from) + SignExtend((instruction >> 5) & 0x7ffff, 19) * 4;
        Materialize(output, reg, address);
        const uint32_t load = opcode == 0 ? 0xB9400000u : opcode == 1 ? 0xF9400000u : 0xB9800000u;
        output.push_back(load | (reg << 5) | reg); // LDR W/X or LDRSW, [Xd]
    } else {
        const bool conditional = (instruction & 0xFF000000u) == 0x54000000u;
        const bool compare = (instruction & 0x7E000000u) == 0x34000000u;
        const bool test = (instruction & 0x7E000000u) == 0x36000000u;
        if (conditional || compare || test) {
            const auto immediate = test ? ((instruction >> 5) & 0x3fff) : ((instruction >> 5) & 0x7ffff);
            const auto destination = from + SignExtend(immediate, test ? 14 : 19) * 4;
            if (conditional && (instruction & 15) >= 14) {
                const auto always = Branch(to, destination);
                if (!always) return std::nullopt;
                return std::vector<uint32_t>{*always};
            }
            const auto branch = Branch(to + 4, destination);
            if (!branch) return std::nullopt;
            const auto mask = test ? 0x0007FFE0u : 0x00FFFFE0u;
            // Invert the original condition and skip the taken branch. No scratch
            // register, stack slot, or condition flag is modified by this expansion.
            output.push_back(((instruction ^ (conditional ? 1u : 1u << 24)) & ~mask) | (2u << 5));
            output.push_back(*branch);
        } else {
            output.push_back(instruction); // register/immediate operation with no PC-relative operand
        }
    }
    auto continuation = Branch(to + output.size() * 4, from + 4);
    if (!continuation) return std::nullopt;
    output.push_back(*continuation);
    return output;
}
}
