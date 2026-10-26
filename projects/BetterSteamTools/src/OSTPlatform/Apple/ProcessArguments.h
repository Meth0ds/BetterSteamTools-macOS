#pragma once
#include <cstdint>
#include <optional>
#include <string>
#include <vector>
namespace OSTPlatform::Apple {
std::optional<std::vector<std::string>> GetProcessArguments(uint32_t pid);
}
