#!/usr/bin/env python3
import pathlib
import subprocess
import tempfile
import unittest
from resolve_anchors import Image, MalformedImage


class AnchorResolutionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="bst-anchors-")
        root = pathlib.Path(cls.temporary.name)
        source = root / "fixture.s"
        source.write_text('''
.section __TEXT,__text,regular,pure_instructions
.globl _unique_function
.p2align 2
_unique_function:
    adrp x0, Lunique@PAGE
    add x0, x0, Lunique@PAGEOFF
    ret
.globl _ambiguous_one
.p2align 2
_ambiguous_one:
    adrp x0, Lshared@PAGE
    add x0, x0, Lshared@PAGEOFF
    ret
.globl _ambiguous_two
.p2align 2
_ambiguous_two:
    adrp x0, Lshared@PAGE
    add x0, x0, Lshared@PAGEOFF
    ret
.section __TEXT,__cstring,cstring_literals
Lunique: .asciz "UniqueAnchor"
Lshared: .asciz "SharedAnchor"
''')
        dylib = root / "fixture.dylib"
        subprocess.run(["xcrun", "clang", "-target", "arm64-apple-macos15.0", "-dynamiclib", str(source), "-o", str(dylib)], check=True, capture_output=True)
        cls.bytes = dylib.read_bytes()

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def test_unique_candidate(self):
        result = Image(self.bytes).locate(["UniqueAnchor"])[0]
        self.assertTrue(result["uniqueFunctionCandidate"])
        self.assertEqual(len(result["references"]), 1)

    def test_ambiguous_not_approved(self):
        result = Image(self.bytes).locate(["SharedAnchor"])[0]
        self.assertFalse(result["uniqueFunctionCandidate"])
        self.assertEqual(len(result["references"]), 2)

    def test_absent_anchor_not_candidate(self):
        result = Image(self.bytes).locate(["NotAnAnchor"])[0]
        self.assertFalse(result["uniqueFunctionCandidate"])
        self.assertEqual(result["references"], [])

    def test_truncation_is_rejected(self):
        with self.assertRaises((MalformedImage, ValueError)):
            Image(self.bytes[:32])


if __name__ == "__main__":
    unittest.main()
