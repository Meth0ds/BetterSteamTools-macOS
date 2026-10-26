#!/usr/bin/env python3
"""Locate ARM64 function candidates without guessing or approving runtime hooks.

Input is an unmodified Valve Mach-O file. Output is analysis data, never a loadable
profile: every candidate still needs ABI/layout review and runtime validation.
Only a function with one unique containing function may progress to that review.
"""
import argparse
import bisect
import hashlib
import json
import pathlib
import struct


class MalformedImage(ValueError):
    pass


class Image:
    def __init__(self, data):
        self.original = data
        self.base = 0
        if len(data) < 32:
            raise MalformedImage("truncated header")
        magic = struct.unpack_from(">I", data)[0]
        if magic in (0xCAFEBABE, 0xCAFEBABF):
            count = struct.unpack_from(">I", data, 4)[0]
            stride = 32 if magic == 0xCAFEBABF else 20
            if count > 32 or len(data) < 8 + count * stride:
                raise MalformedImage("invalid universal header")
            found = []
            for index in range(count):
                offset = 8 + index * stride
                cpu = struct.unpack_from(">I", data, offset)[0]
                fmt = ">QQ" if stride == 32 else ">II"
                begin, size = struct.unpack_from(fmt, data, offset + 8)
                if begin > len(data) or size > len(data) - begin:
                    raise MalformedImage("universal slice outside file")
                if cpu == 0x0100000C:
                    found.append((begin, size))
            if len(found) != 1:
                raise MalformedImage("expected exactly one ARM64 slice")
            self.base, size = found[0]
            data = memoryview(data)[self.base:self.base + size]
        self.data = data
        magic, cpu, _, _, count, command_bytes, _, _ = struct.unpack_from("<IIIIIIII", data)
        if magic != 0xFEEDFACF or cpu != 0x0100000C or command_bytes > len(data) - 32:
            raise MalformedImage("expected little-endian ARM64 Mach-O")
        self.sections = []
        self.text_base = None
        starts = None
        cursor = 32
        for _ in range(count):
            if cursor > 32 + command_bytes - 8:
                raise MalformedImage("truncated load command")
            command, size = struct.unpack_from("<II", data, cursor)
            if size < 8 or size > 32 + command_bytes - cursor:
                raise MalformedImage("invalid load command size")
            if command == 0x19:
                if size < 72:
                    raise MalformedImage("truncated segment")
                name = bytes(data[cursor+8:cursor+24]).rstrip(b"\0")
                vmaddr = struct.unpack_from("<Q", data, cursor + 24)[0]
                nsects = struct.unpack_from("<I", data, cursor + 64)[0]
                if nsects > (size - 72) // 80:
                    raise MalformedImage("invalid section count")
                if name == b"__TEXT":
                    self.text_base = vmaddr
                for index in range(nsects):
                    section = cursor + 72 + index * 80
                    section_name = bytes(data[section:section+16]).rstrip(b"\0").decode("ascii")
                    addr, length, file_offset = struct.unpack_from("<QQI", data, section + 32)
                    flags = struct.unpack_from("<I", data, section + 64)[0]
                    # Zerofill sections have no on-disk bytes.
                    if flags & 0xff not in (1, 0xc, 0x12) and (file_offset > len(data) or length > len(data) - file_offset):
                        raise MalformedImage("section outside file")
                    self.sections.append((section_name, addr, length, file_offset))
            elif command == 0x26:
                if size < 16:
                    raise MalformedImage("truncated function starts")
                starts = struct.unpack_from("<II", data, cursor + 8)
            cursor += size
        if self.text_base is None or starts is None:
            raise MalformedImage("missing text segment or function boundaries")
        offset, size = starts
        if offset > len(data) or size > len(data) - offset:
            raise MalformedImage("function starts outside file")
        self.starts = []
        address = self.text_base
        value = shift = 0
        for byte in data[offset:offset+size]:
            value |= (byte & 127) << shift
            if byte & 128:
                shift += 7
                if shift > 63:
                    raise MalformedImage("function delta overflow")
            else:
                if value == 0:
                    break
                address += value
                self.starts.append(address)
                value = shift = 0
        if not self.starts or shift:
            raise MalformedImage("invalid function boundaries")

    def function(self, address):
        index = bisect.bisect_right(self.starts, address) - 1
        if index < 0:
            return None
        end = self.starts[index+1] if index+1 < len(self.starts) else next((base + size for name, base, size, _ in self.sections if name == "__text" and base <= address < base + size), None)
        return self.starts[index] if end is not None and address < end else None

    def locate(self, anchors):
        wanted = {}
        for name in anchors:
            encoded = name.encode("utf8") + b"\0"
            addresses = []
            for section, address, size, offset in self.sections:
                if section not in ("__cstring", "__const"):
                    continue
                block = bytes(self.data[offset:offset+size])
                cursor = 0
                while (cursor := block.find(encoded, cursor)) != -1:
                    if cursor == 0 or block[cursor-1] == 0:
                        addresses.append(address+cursor)
                    cursor += 1
            for address in addresses:
                wanted[address] = name
        references = {name: [] for name in anchors}
        for section, address, size, offset in self.sections:
            if section != "__text":
                continue
            for index in range(0, size - 4, 4):
                instruction = struct.unpack_from("<I", self.data, offset + index)[0]
                if instruction & 0x9F000000 != 0x90000000:  # ADRP
                    continue
                register = instruction & 31
                immediate = ((instruction >> 5) & 0x7ffff) << 2 | ((instruction >> 29) & 3)
                if immediate & (1 << 20):
                    immediate -= 1 << 21
                page = ((address+index) & ~4095) + (immediate << 12)
                # Adjacent ADRP/ADD is unambiguous and does not require emulating
                # unknown instructions that may overwrite the tracked register.
                add = struct.unpack_from("<I", self.data, offset + index + 4)[0]
                if add & 0xFF000000 != 0x91000000 or ((add >> 5) & 31) != register:
                    continue
                immediate = (add >> 10) & 0xfff
                if add & (1 << 22):
                    immediate <<= 12
                target = page + immediate
                if target not in wanted:
                    continue
                start = self.function(address + index)
                if start is None:
                    continue
                references[wanted[target]].append({
                    "functionRVA": hex(start - self.text_base),
                    "referenceRVA": hex(address + index - self.text_base),
                    "anchorRVA": hex(target - self.text_base),
                })
        return [{"anchor": name, "references": references[name],
                 "uniqueFunctionCandidate": len({ref["functionRVA"] for ref in references[name]}) == 1}
                for name in anchors]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=pathlib.Path)
    parser.add_argument("--anchor", action="append", required=True)
    args = parser.parse_args()
    data = args.image.read_bytes()
    image = Image(data)
    print(json.dumps({"format": "analysis-only", "runtimeApproved": False,
                      "sha256": hashlib.sha256(data).hexdigest(), "architecture": "arm64",
                      "candidates": image.locate(args.anchor)}, indent=2))


if __name__ == "__main__":
    main()
