#include <loongarch.h>
#include <asm/loongisa_csr.h>
#include <trap.h>
#include <stdio.h>
#include <picirq.h>
//#include <sched.h>

volatile size_t ticks;


#define HZ 100

static void reload_timer()
{
  write_csr_tmintclear(CSR_TMINTCLR_TI);
}

int clock_int_handler(void * data)
{
#ifdef LAB1_EX4
  // LAB1 EXERCISE4: YOUR CODE
  // (1) count ticks here
  ticks ++;
#ifdef _SHOW_100_TICKS
  // (2) if ticks % 100 == 0 then call kprintf to print "100 ticks"
  if (ticks % 100 == 0) {
    kprintf("100 ticks\n");
  }
#endif
#endif
#ifdef LAB7_EX1
  run_timer_list();
#endif
#ifdef LAB8_EX2
  // 2026-final: chiplab/nscscc adaptation
  // The nscscc-team SoC ties CPU intrpt[7:0] to 8'd0 (chip/soc_demo/
  // nscscc-team/soc_top.v), so the 16550 RX interrupt line never fires.
  // Poll the UART RX FIFO at timer frequency and feed the stdin buffer,
  // otherwise the shell would block in dev_stdin_read() forever.
  {
    extern void serial_int_handler(void*);
    serial_int_handler(NULL);
  }
#endif
  reload_timer();
  return 0;
}

void
clock_init(void) {
  // setup timer
  unsigned long timer_config;
  // 2026-final: chiplab/nscscc adaptation
  // Upstream assumed a 200MHz constant-frequency counter (QEMU ls3a5k32).
  // Our LA32R core's stable counter runs at the CPU clock, 105MHz, so
  // 100Hz ticks need 105000000/100 = 1050000 counts.
  unsigned long period = 105000000;
  period = period / HZ;
  timer_config = period & LISA_CSR_TMCFG_TIMEVAL;
  timer_config |= (LISA_CSR_TMCFG_PERIOD | LISA_CSR_TMCFG_EN);
  __csrwr(timer_config, LISA_CSR_TMCFG);
  pic_enable(TIMER0_IRQ);
  kprintf("++setup timer interrupts\n");
}

