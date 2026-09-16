.text
.p2align 2
.globl _pbr_legacy_send_island
.globl _pbr_legacy_dlsym_branch
.globl _pbr_legacy_resume_branch
.globl _pbr_legacy_replay
_pbr_legacy_send_island:
    stp x29, x30, [sp, #-112]!
    mov x29, sp
    stp x0, x1, [sp, #16]
    stp x2, x3, [sp, #32]
    stp x4, x5, [sp, #48]
    stp x6, x7, [sp, #64]
    str x8, [sp, #80]
    mov x0, #-2
    adr x1, Lname
_pbr_legacy_dlsym_branch:
    .long 0x94000000
    cbz x0, Lfallback
    mov x16, x0
    ldp x0, x1, [sp, #16]
    ldp x2, x3, [sp, #32]
    ldp x4, x5, [sp, #48]
    ldp x6, x7, [sp, #64]
    ldr x8, [sp, #80]
    blr x16
    cbz w0, Lfallback
    ldp x29, x30, [sp], #112
    ret
Lfallback:
    ldp x0, x1, [sp, #16]
    ldp x2, x3, [sp, #32]
    ldp x4, x5, [sp, #48]
    ldp x6, x7, [sp, #64]
    ldr x8, [sp, #80]
    ldp x29, x30, [sp], #112
_pbr_legacy_replay:
    sub sp, sp, #320
    stp x28, x27, [sp, #224]
    stp x26, x25, [sp, #240]
    stp x24, x23, [sp, #256]
_pbr_legacy_resume_branch:
    .long 0x14000000
Lname:
    .asciz "PBRLegacyOutbound"
.p2align 2
