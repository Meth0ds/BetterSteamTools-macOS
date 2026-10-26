#include "../MachOImageLayout.h"
#include <mach-o/loader.h>
#include <mach/vm_prot.h>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <vector>

void check(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
template<class T> void put(std::vector<uint8_t>& data, size_t offset, const T& value) { std::memcpy(data.data() + offset, &value, sizeof value); }
int main() {
    try {
        mach_header_64 header{}; header.magic = MH_MAGIC_64; header.cputype = CPU_TYPE_ARM64; header.filetype = MH_DYLIB;
        header.ncmds = 1; header.sizeofcmds = sizeof(segment_command_64) + sizeof(section_64);
        segment_command_64 segment{}; segment.cmd = LC_SEGMENT_64; segment.cmdsize = header.sizeofcmds;
        std::strcpy(segment.segname, "__TEXT"); segment.vmaddr = 0x100000; segment.vmsize = 0x10000;
        segment.initprot = VM_PROT_READ | VM_PROT_EXECUTE; segment.nsects = 1;
        section_64 section{}; std::strcpy(section.segname, "__TEXT"); std::strcpy(section.sectname, "__text");
        section.addr = segment.vmaddr + 0x4000; section.size = 0x8000; section.flags = S_ATTR_PURE_INSTRUCTIONS;
        std::vector<uint8_t> bytes(sizeof header + header.sizeofcmds);
        const auto reset = [&] { put(bytes, 0, header); put(bytes, sizeof header, segment); put(bytes, sizeof header + sizeof segment, section); };
        reset(); auto layout = BST::Mac::MachOImageLayout::parse(bytes);
        check(layout.has_value(), "valid image layout");
        check(layout->codeAddress(0x200000, 0x4010, 16) == 0x304010, "RVA uses segment base, not section base");
        check(layout->codeAddress(-0x100000, 0x4010, 16) == 0x4010, "negative dyld slide");
        check(!layout->codeAddress(0, 0x100, 4), "header is not a code entry");
        check(!layout->codeAddress(0, 0xbffc, 8), "entry cannot cross section end");
        check(!layout->codeAddress(INTPTR_MAX, UINT64_MAX, 4), "RVA overflow rejected");
        check(!layout->codeAddress(INTPTR_MIN, 0x4000, 4), "slide underflow rejected");
        check(!layout->codeAddress(0, 0x4000, 0), "zero byte range rejected");
        bytes.pop_back(); check(!BST::Mac::MachOImageLayout::parse(bytes), "truncated commands rejected"); bytes.push_back(0); reset();
        auto badSegment = segment; badSegment.cmdsize = 0; put(bytes, sizeof header, badSegment);
        check(!BST::Mac::MachOImageLayout::parse(bytes), "zero command size rejected"); reset();
        badSegment = segment; badSegment.nsects = UINT32_MAX; put(bytes, sizeof header, badSegment);
        check(!BST::Mac::MachOImageLayout::parse(bytes), "section table overflow rejected"); reset();
        auto badSection = section; badSection.addr = 0x110000; put(bytes, sizeof header + sizeof segment, badSection);
        check(!BST::Mac::MachOImageLayout::parse(bytes), "section outside segment rejected"); reset();
        badSegment = segment; badSegment.initprot |= VM_PROT_WRITE; put(bytes, sizeof header, badSegment);
        check(!BST::Mac::MachOImageLayout::parse(bytes), "writable text rejected"); reset();
        header.ncmds = 2; put(bytes, 0, header); check(!BST::Mac::MachOImageLayout::parse(bytes), "command count must match bytes");
        std::cout << "PASS: Mach-O RVA, slide, executable section and load-command bounds\n";
        return 0;
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
