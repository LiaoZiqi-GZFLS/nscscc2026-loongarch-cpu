#include <defs.h>
#include <loongarch.h>
#include <stdio.h>
#include <string.h>
#include <picirq.h>
#include <intr.h>

/* stupid I/O delay routine necessitated by historical PC design flaws */
static void
delay(void) {
}

/***** Serial I/O code *****/

#define COM_RX          0       // In:  Receive buffer (DLAB=0)
#define COM_TX          0       // Out: Transmit buffer (DLAB=0)
#define COM_DLL         0       // Out: Divisor Latch Low (DLAB=1)
#define COM_DLM         1       // Out: Divisor Latch High (DLAB=1)
#define COM_IER         1       // Out: Interrupt Enable Register
#define COM_IER_RDI     0x01    // Enable receiver data interrupt
#define COM_IIR         2       // In:  Interrupt ID Register
#define COM_FCR         2       // Out: FIFO Control Register
#define COM_LCR         3       // Out: Line Control Register
#define COM_LCR_DLAB    0x80    // Divisor latch access bit
#define COM_LCR_WLEN8   0x03    // Wordlength: 8 bits
#define COM_MCR         4       // Out: Modem Control Register
#define COM_MCR_RTS     0x02    // RTS complement
#define COM_MCR_DTR     0x01    // DTR complement
#define COM_MCR_OUT2    0x08    // Out2 complement
#define COM_LSR         5       // In:  Line Status Register
#define COM_LSR_DATA    0x01    // Data available
#define COM_LSR_TXRDY   0x20    // Transmit buffer avail
#define COM_LSR_TSRE    0x40    // Transmitter off


static bool serial_exists = 0;

static void
serial_init(void) {
    volatile unsigned char *uart = (unsigned char*)COM1;
    if(serial_exists)
      return ;
    serial_exists = 1;
    // 2026-final: chiplab/nscscc adaptation (rev2: real-board baud rate)
    // Init sequence for the Loongson URT 16550 at phys 0x1fe001e0, mirrors
    // sw/boot/start.S (see COM1_BAUD_* in loongarch.h): DLAB=1 -> DLL/DLM ->
    // DL3 fractional divider (register offset 2 aliases FCR while DLAB=1) ->
    // 8N1 -> FIFO on. Real board: 100MHz sys_clk, 115200 baud (DLL=0x36,
    // DL3=0x40). Verilator sim: -DUCORE_VERILATOR_UART keeps divisor=1.
    // Set speed; requires DLAB latch
    outb(COM1 + COM_LCR, COM_LCR_DLAB);
#ifdef UCORE_VERILATOR_UART
    outb(COM1 + COM_DLL, 1);
    outb(COM1 + COM_DLM, 0);
    outb(COM1 + COM_FCR, 0);        // DL3 while DLAB=1; 0 in sim
#else
    outb(COM1 + COM_DLL, (uint8_t) (COM1_BAUD_DLL));
    outb(COM1 + COM_DLM, (uint8_t) (COM1_BAUD_DLM));
    outb(COM1 + COM_FCR, (uint8_t) (COM1_BAUD_DL3)); // DL3 (Loongson frac) while DLAB=1
#endif

    // 8 data bits, 1 stop bit, parity off; turn off DLAB latch
    outb(COM1 + COM_LCR, COM_LCR_WLEN8 & ~COM_LCR_DLAB);

    // Enable FIFO + reset both FIFOs, 4-byte trigger (chiplab convention)
    outb(COM1 + COM_FCR, 0x47);

    // No modem controls
    outb(COM1 + COM_MCR, 0);
    // Enable rcv interrupts
    outb(COM1 + COM_IER, COM_IER_RDI);

    pic_enable(COM1_IRQ);
}


static void
serial_putc_sub(int c) {
    while (!(inb(COM1 + COM_LSR) & COM_LSR_TXRDY)) {
    }
    outb(COM1 + COM_TX, c);
}

/* serial_putc - print character to serial port */
static void
serial_putc(int c) {
    if (c == '\n') {
        serial_putc_sub('\r');
        serial_putc_sub('\n');
    }else {
        serial_putc_sub(c);
    }
}

/* serial_proc_data - get data from serial port */
static int
serial_proc_data(void) {
    int c;
    if (!(inb(COM1 + COM_LSR) & COM_LSR_DATA)) {
        return -1;
    }
    c = inb(COM1 + COM_RX);
    return c;
}


void serial_int_handler(void *opaque)
{
    unsigned char id = inb(COM1+COM_IIR);
    if(id & 0x01)
        return ;
    //int c = serial_proc_data();
    int c = cons_getc();
#if defined(LAB1_EX4) && defined(_SHOW_SERIAL_INPUT)
    // LAB1 EXERCISE4: YOUR CODE
    kprintf("got input %c\n",c);
#endif
#ifdef LAB8_EX2
    extern void dev_stdin_write(char c);
    dev_stdin_write(c);
#endif
}

/* *
 * Here we manage the console input buffer, where we stash characters
 * received from the keyboard or serial port whenever the corresponding
 * interrupt occurs.
 * */

#define CONSBUFSIZE 512

static struct {
    uint8_t buf[CONSBUFSIZE];
    uint32_t rpos;
    uint32_t wpos;
} cons;

/* *
 * cons_intr - called by device interrupt routines to feed input
 * characters into the circular console input buffer.
 * */
static void
cons_intr(int (*proc)(void)) {
    int c;
    while ((c = (*proc)()) != -1) {
        if (c != 0) {
            cons.buf[cons.wpos ++] = c;
            if (cons.wpos == CONSBUFSIZE) {
                cons.wpos = 0;
            }
        }
    }
}

/* serial_intr - try to feed input characters from serial port */
void
serial_intr(void) {
    if (serial_exists) {
        cons_intr(serial_proc_data);
    }
}

/* cons_init - initializes the console devices */
void
cons_init(void) {
    serial_init();
    //cons.rpos = cons.wpos = 0;
    if (!serial_exists) {
        kprintf("serial port does not exist!!\n");
    }
}

/* cons_putc - print a single character @c to console devices */
void
cons_putc(int c) {
    long intr_flag;
    local_intr_save(intr_flag);
    {
        serial_putc(c);
    }
    local_intr_restore(intr_flag);
}

/* *
 * cons_getc - return the next input character from console,
 * or 0 if none waiting.
 * */
int
cons_getc(void) {
    int c = 0;
    long intr_flag;
    local_intr_save(intr_flag);
    {
        // poll for any pending input characters,
        // so that this function works even when interrupts are disabled
        // (e.g., when called from the kernel monitor).
        serial_intr();

        // grab the next character from the input buffer.
        if (cons.rpos != cons.wpos) {
            c = cons.buf[cons.rpos ++];
            if (cons.rpos == CONSBUFSIZE) {
                cons.rpos = 0;
            }
        }
    }
    local_intr_restore(intr_flag);
    return c;
}

