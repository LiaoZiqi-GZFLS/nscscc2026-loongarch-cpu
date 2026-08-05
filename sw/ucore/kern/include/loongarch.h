#ifndef __LIBS_LOONGARCH_H__
#define __LIBS_LOONGARCH_H__

#include <defs.h>

#define do_div(n, base) ({                                          \
            unsigned long __mod;    \
            (__mod) = ((unsigned long)n) % (base);                                \
            (n) = ((unsigned long)n) / (base);                                          \
            __mod;                                                  \
        })

#define barrier() __asm__ __volatile__ ("" ::: "memory")

#define __read_reg(source) (\
    {int __res;\
    __asm__ __volatile__("move %0, " #source "\n\t"\
      : "=r"(__res));\
    __res;\
    })

static inline unsigned int __mulu10(unsigned int n)
{
    return (n<<3)+(n<<1);
}

/* __divu* routines are from the book, Hacker's Delight */

static inline unsigned int __divu10(unsigned int n) {
    unsigned int q, r;
    q = (n >> 1) + (n >> 2);
    q = q + (q >> 4);
    q = q + (q >> 8);
    q = q + (q >> 16);
    q = q >> 3;
    r = n - __mulu10(q);
    return q + ((r + 6) >> 4);
}

static inline unsigned __divu5(unsigned int n) {
    unsigned int q, r;
    q = (n >> 3) + (n >> 4);
    q = q + (q >> 4);
    q = q + (q >> 8);
    q = q + (q >> 16);
    r = n - q*5;
    return q + (13*r >> 6);
}


static inline uint8_t inb(uint32_t port) __attribute__((always_inline));
static inline void outb(uint32_t port, uint8_t data) __attribute__((always_inline));
static inline uint32_t inw(uint32_t port) __attribute__((always_inline));
static inline void outw(uint32_t port, uint32_t data) __attribute__((always_inline));

static inline uint8_t
inb(uint32_t port) {
    uint8_t data = *((const volatile uint8_t*) port);
    return data;
}

static inline void
outb(uint32_t port, uint8_t data) {
    *((volatile uint8_t*) port) = data;
}

static inline uint32_t
inw(uint32_t port) {
    uint32_t data = *((volatile uintptr_t *) port);
    return data;
}

static inline void
outw(uint32_t port, uint32_t data) {
    *((volatile uintptr_t *) port) = data;
}


/* board specification */
// 2026-final: chiplab/nscscc adaptation
// COM1 = DMWIN1 uncached window (0x80000000) + chiplab UART16550 phys base
// 0x1fe001e0 = 0x9fe001e0. This matches upstream; no change needed.
#define COM1            0x9fe001e0
// NOTE: nscscc-team SoC ties intrpt[7:0] to 0, so this IRQ never fires;
// console input is polled from the timer interrupt (see clock.c).
#define COM1_IRQ        3
// 2026-final: chiplab/nscscc adaptation (rev2: real-board baud rate)
// The chiplab 16550 (Loongson URT, IP/APB_DEV/URT/uart_regs.v) is clocked by
// PCLK = sys_clk = 100 MHz on the nscscc-team SoC (clk_pll clk_out2; contest
// rules fix sys_clk, only cpu_clk is configurable). Its baud generator is a
// 24-bit fractional divider {DL3[7:0], DLM, DLL}, baud = PCLK/(16*dl), where
// DL3 is a first-order DSM fractional register reachable at register offset 2
// while DLAB=1 (plain 16550s ignore it).
//   100 MHz / 115200 -> dl = 54.2539 -> DLL=54(0x36), DL3=64(0x40)
//   => 115212 baud, -0.06% error. Same values as sw/boot (verified there).
// Override the clock with -DUART_PCLK=<hz>. For verilator simulation (whose
// C++ UART model ignores timing/baud entirely) build with
// -DUCORE_VERILATOR_UART to use divisor=1, the chiplab sim convention
// (software/examples/linux/start.S).
#ifndef UART_PCLK
#define UART_PCLK       100000000
#endif
#ifndef UART_BAUD
#define UART_BAUD       115200
#endif
#define COM1_BAUD_DIV   ((UART_PCLK + 8 * UART_BAUD) / (16 * UART_BAUD))
#define COM1_BAUD_DLL   (COM1_BAUD_DIV & 0xff)          /* 0x36 @ 100MHz/115200 */
#define COM1_BAUD_DLM   ((COM1_BAUD_DIV >> 8) & 0xff)   /* 0x00 */
#define COM1_BAUD_DL3   ((((UART_PCLK % (16 * UART_BAUD)) * 256) / (16 * UART_BAUD)) & 0xff) /* 0x40 */

#define TIMER0_IRQ      11

// 2026-final: chiplab/nscscc adaptation
// Our LA32R core (NOP core, MyCPUConfig.scala) has 64-byte I/D cache lines,
// not 16. fence_i() below steps CACOP by CACHELINE_SIZE; a wrong value would
// leave stale i-cache lines.
#define CACHELINE_SIZE  64

static void fence_i(void *va_start, int size) {
    /*
        The fence_i function is used for make d-cache sync to i-cache so we can correctly execute modified code.

        As loongarch32 didn't guarantee any cache coherence, we need to make dirty d-cache writeback to memory and invalidte it from i-cache. 

        This operation is not necessary when running on ISA level emulator like QEMU, but it must be done when running on real hardware or FPGA.
     */
    asm volatile(".word 0b00111000011100100000000000000000"); // dbar, used for out-of-order machine
    void *va_end = va_start + size;
    while (va_start < va_end) {
        asm volatile("cacop 9, %0 ,0": "=r"(va_start)); // code[2:0]=1->d-cache, code[4:3]=2->index invalidate and writeback
        asm volatile("cacop 8, %0 ,0": "=r"(va_start)); // code[2:0]=0->i-cache, code[4:3]=2->index invalidate
        va_start += CACHELINE_SIZE;
    }
    asm volatile(".word 0b00111000011100101000000000000000"); // ibar, used for flush pipeline and instruction buffer.
}

#endif /* !__LIBS_LOONGARCH_H__ */

