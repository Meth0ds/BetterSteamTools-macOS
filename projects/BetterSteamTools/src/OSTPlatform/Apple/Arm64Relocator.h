#pragma once
#include <cstdint>
#include <optional>
#include <vector>

namespace OSTPlatform::Apple::Arm64 {
// Every redirect replaces exactly one aligned instruction. Relocation is bounded
// to that instruction; an unrecognized control-flow entry is rejected.
std::optional<uint32_t> Branch(uintptr_t from, uintptr_t to);
std::optional<std::vector<uint32_t>> RelocateEntry(uint32_t instruction, uintptr_t from, uintptr_t to);
}
