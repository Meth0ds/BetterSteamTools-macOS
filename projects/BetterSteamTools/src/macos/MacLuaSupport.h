#pragma once
#include <lua.hpp>
#include <filesystem>
#include <string>
#include <vector>
namespace BST::Mac::LuaSupport {
struct Diagnostic { std::string file; std::string message; };
class ExecutionBudget {
public:
    explicit ExecutionBudget(lua_State* state);
    ~ExecutionBudget();
    ExecutionBudget(const ExecutionBudget&) = delete;
    ExecutionBudget& operator=(const ExecutionBudget&) = delete;
private:
    lua_State* state_;
    lua_Hook previous_;
    int previousMask_, previousCount_;
    void* budget_;
};
bool ExecuteFile(lua_State* state, const std::filesystem::path& path);
void Report(const std::string& file, const char* message);
std::vector<Diagnostic> TakeDiagnostics();
}
