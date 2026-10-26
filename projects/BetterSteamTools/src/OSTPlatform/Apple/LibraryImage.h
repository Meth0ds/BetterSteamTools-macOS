#pragma once
#include "include/DynamicLibrary.h"
#include <mach-o/loader.h>
namespace OSTPlatform::Apple {
const mach_header_64* ImageHeader(DynamicLibrary::ModuleHandle module, intptr_t& slide);
}
