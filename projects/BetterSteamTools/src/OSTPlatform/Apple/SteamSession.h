#pragma once
#include <cstdint>
#include <optional>
#include <string>
#include <vector>
namespace OSTPlatform::Apple {
struct SteamSession { uint32_t accountID; std::wstring universe; };
std::optional<SteamSession> ParseSteamHelperSession(const std::vector<std::string>& arguments, uint32_t steamPID);
}
