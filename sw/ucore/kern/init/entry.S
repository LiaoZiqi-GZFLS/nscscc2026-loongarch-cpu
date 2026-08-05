#include <asm/regdef.h>
#include <asm/loongisa_csr.h>

.global kernel_entry
.extern kern_init

.extern edata
.extern end

.section .startup

#define KSTACKSIZE (4096*2)

kernel_entry:
  b reset
  nop
    .align 4
reset:
    // 2026-final: chiplab/nscscc adaptation
    // This entry now tolerates BOTH handoff styles:
    //  (a) PMON-style: entered at the linked virtual address (0xbc000000)
    //      with PG already enabled and DMWs configured;
    //  (b) bare-metal/chiplab-style: entered at the physical load address
    //      0x1c000000 in DA mode (CRMD.DA=1, PG=0).
    // The sequence below is register-only until the mode switch, so it is
    // safe to execute from either address.
    //
    // DMWIN0: 0xa0000000-0xbfffffff->0x00000000-0x1fffffff Cached
    li.w    t0, 0xa0000011
    csrwr   t0, LISA_CSR_DMWIN0
    // DMWIN1 (temporary): identity map 0x00000000-0x1fffffff->itself.
    // This keeps instruction fetch alive across the DA->PG switch when we
    // were entered at a physical address (same trick as chiplab
    // software/examples/linux/start.S). Our core only implements DMW0/DMW1
    // (CSRPlugin.scala), so the identity window MUST go in DMW1, not DMW2.
    li.w    t0, 0x00000001
    csrwr   t0, LISA_CSR_DMWIN1
    // Set PG=1, DA=0 (mask = DA|PG). If PG was already on this is a no-op.
    li.w    t0, 0x10    // PG
    li.w    t1, 0x18    // DA|PG
    csrxchg t0, t1, LISA_CSR_CRMD
    // Jump to the linked virtual address of 1f. In case (b) we were executing
    // at PA 0x1c0000xx (kept alive by the identity window); the jump lands in
    // the cached DMWIN0 window. In case (a) this is what upstream did.
    la t0, 1f
    jirl zero, t0, 0
1:
    // DMWIN1: 0x80000000-0x9fffffff->0x00000000-0x1fffffff Uncached (serial port is here)
    li.w    t0, 0x80000001
    csrwr   t0, LISA_CSR_DMWIN1
    // Restore upstream's final CRMD state (PLV=0, IE=0, PG, DATF/DATM=01)
    li.w    t0, 0xb0
    csrwr   t0, LISA_CSR_CRMD
    la sp, bootstacktop
#zero bss
    la t0, edata
    la t1, end
2:
    st.w zero, t0, 0
    addi.w t0, t0, 4
    slt t3, t0, t1
    bgtz t3, 2b
    addi.w sp, sp, -16
    b kern_init

.section .data
    .global bootstack
bootstack:
    .space KSTACKSIZE
    .global bootstacktop
bootstacktop:
    .space 32