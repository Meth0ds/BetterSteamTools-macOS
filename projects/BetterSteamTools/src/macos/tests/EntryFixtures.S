.text
.p2align 4
.globl _bst_fixture_add
_bst_fixture_add:
    add x0, x0, #1
    ret

.p2align 4
.globl _bst_fixture_prologue
_bst_fixture_prologue:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    add x0, x0, #2
    ldp x29, x30, [sp], #16
    ret

.p2align 4
.globl _bst_fixture_pac
_bst_fixture_pac:
    paciasp
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    add x0, x0, #3
    ldp x29, x30, [sp], #16
    autiasp
    ret

.p2align 4
.globl _bst_fixture_adr
_bst_fixture_adr:
    adr x0, Laddress
    ret
Laddress:
    .quad 0x12345678

.p2align 4
.globl _bst_fixture_adrp
_bst_fixture_adrp:
    adrp x0, _bst_fixture_value@PAGE
    add x0, x0, _bst_fixture_value@PAGEOFF
    ret

.p2align 4
.globl _bst_fixture_literal
_bst_fixture_literal:
    ldr x0, Lliteral
    ret
Lliteral:
    .quad 0x1234567890abcdef

.p2align 4
.globl _bst_fixture_literal32
_bst_fixture_literal32:
    ldr w0, Lliteral32
    ret
Lliteral32:
    .long 0xfedcba98

.p2align 4
.globl _bst_fixture_literalsigned
_bst_fixture_literalsigned:
    ldrsw x0, Lliteralsigned
    ret
Lliteralsigned:
    .long -7

.p2align 4
.globl _bst_fixture_cbz
_bst_fixture_cbz:
    cbz x0, Lzero
    add x0, x0, #2
    ret
Lzero:
    mov x0, #11
    ret

.p2align 4
.globl _bst_fixture_cbnz
_bst_fixture_cbnz:
    cbnz x0, Lnonzero
    mov x0, #13
    ret
Lnonzero:
    add x0, x0, #3
    ret

.p2align 4
.globl _bst_fixture_tbz
_bst_fixture_tbz:
    tbz x0, #3, Lbitzero
    add x0, x0, #4
    ret
Lbitzero:
    mov x0, #17
    ret

.p2align 4
.globl _bst_fixture_tbnz
_bst_fixture_tbnz:
    tbnz x0, #3, Lbitnonzero
    mov x0, #19
    ret
Lbitnonzero:
    add x0, x0, #5
    ret

.p2align 4
.globl _bst_fixture_cond_caller
_bst_fixture_cond_caller:
    cmp x0, #0
    b _bst_fixture_cond
.globl _bst_fixture_cond
_bst_fixture_cond:
    b.eq Lcondzero
    add x0, x0, #6
    ret
Lcondzero:
    mov x0, #23
    ret

.p2align 4
.globl _bst_fixture_always
_bst_fixture_always:
    b.al Lalways
    mov x0, #31
    ret
Lalways:
    mov x0, #29
    ret

.p2align 4
.globl _bst_fixture_branch
_bst_fixture_branch:
    b _bst_fixture_add

.p2align 4
.globl _bst_fixture_call_with_flags
_bst_fixture_call_with_flags:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    cmp x0, #0
    blr x1
    ldp x29, x30, [sp], #16
    ret

.data
.p2align 3
.globl _bst_fixture_value
_bst_fixture_value:
    .quad 0x1122334455667788
