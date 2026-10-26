#pragma once
#include <string>
namespace OSTPlatform::Apple {
// Per-calling-thread diagnostic for the unchanged cross-platform bool API.
std::string DetourLastError();
}
