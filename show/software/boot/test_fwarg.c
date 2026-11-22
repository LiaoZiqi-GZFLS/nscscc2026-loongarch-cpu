/* Host unit test: replicate build_fw_arg() on a RAM buffer and parse it
 * back with the la32r-Linux 5.14 struct definitions (boot_param.h). */
#include <stdio.h>
#include <string.h>
#include <stdint.h>

#define FWARG_PHYS  0x1CFF0000u
#define MEM_BASE    0x1C000000u
#define MEM_SIZE    0x01000000u
#define KVIRT(x)    (0xA0000000u | (x))
#define OFF_ARGV    0x000
#define OFF_ARGV0_STR 0x020
#define OFF_CMDLINE 0x040
#define OFF_BPI     0x140
#define OFF_MEMNODE 0x160
#define BOOT_CMDLINE "console=ttyS0,115200"

static uint8_t ram[0x400];
#define A(phys) ((phys) - FWARG_PHYS)

static void wr32(uint32_t addr, uint32_t val)
{
    uint8_t *p = &ram[A(addr)];
    p[0] = val & 0xff; p[1] = (val >> 8) & 0xff;
    p[2] = (val >> 16) & 0xff; p[3] = (val >> 24) & 0xff;
}
static void mem_fill(uint32_t dst, uint8_t val, uint32_t n)
{ memset(&ram[A(dst)], val, n); }
static void mem_copy(uint32_t dst, const void *src, uint32_t n)
{ memcpy(&ram[A(dst)], src, n); }
static void str_copy(uint32_t dst, const char *s)
{ strcpy((char *)&ram[A(dst)], s); }

int main(void)
{
    uint32_t a = FWARG_PHYS, mem = a + OFF_MEMNODE;
    uint32_t len = 19 + 2 * 12, sum, i;

    mem_fill(a, 0, 0x400);
    wr32(a + OFF_ARGV + 0, KVIRT(a + OFF_ARGV0_STR));
    wr32(a + OFF_ARGV + 4, KVIRT(a + OFF_CMDLINE));
    str_copy(a + OFF_ARGV0_STR, "boot");
    str_copy(a + OFF_CMDLINE, BOOT_CMDLINE);
    mem_copy(a + OFF_BPI, "BPI01000", 8);
    wr32(a + OFF_BPI + 8, 0);
    wr32(a + OFF_BPI + 12, KVIRT(mem));
    wr32(a + OFF_BPI + 16, 0);
    wr32(a + OFF_BPI + 20, 0);
    mem_copy(mem, "MEM", 3);
    wr32(mem + 8, len);
    wr32(mem + 14, 0);
    ram[A(mem) + 18] = 2;
    wr32(mem + 19 + 0, 1);  wr32(mem + 19 + 4, MEM_BASE); wr32(mem + 19 + 8, MEM_SIZE);
    wr32(mem + 19 + 12, 2); wr32(mem + 19 + 16, FWARG_PHYS); wr32(mem + 19 + 20, 0x10000);
    sum = 0;
    for (i = 0; i < len; i++) sum += ram[A(mem) + i];
    ram[A(mem) + 13] = (uint8_t)(0 - sum);

    /* ---- verify like the kernel does ---- */
    /* cmdline.c: fw_argc=a0, _fw_argv=a1, concat argv[1..] */
    uint32_t *argv = (uint32_t *)&ram[A(OFF_ARGV + FWARG_PHYS)];
    printf("argv[0]=0x%08x -> \"%s\"\n", argv[0], (char *)&ram[A(argv[0] & 0x1fffffff)]);
    printf("argv[1]=0x%08x -> \"%s\"\n", argv[1], (char *)&ram[A(argv[1] & 0x1fffffff)]);
    printf("argv[2]=0x%08x\n", argv[2]);

    /* env.c: efi_bp=(bootparamsinterface*)fw_arg2; extlist walk */
    uint8_t *bpi = &ram[A(OFF_BPI + FWARG_PHYS)];
    printf("bpi sig=\"%.8s\" systable=0x%02x%02x%02x%02x extlist=0x%08x flags=0\n",
           bpi, bpi[11], bpi[10], bpi[9], bpi[8],
           bpi[12] | bpi[13]<<8 | bpi[14]<<16 | bpi[15]<<24);

    /* list_find: memcmp(signature,"MEM",3), then parse_mem + checksum */
    uint8_t *node = &ram[A(OFF_MEMNODE + FWARG_PHYS)];
    uint32_t length = node[8] | node[9]<<8 | node[10]<<16 | node[11]<<24;
    uint32_t next = node[14] | node[15]<<8 | node[16]<<16 | node[17]<<24;
    uint8_t cs = 0;
    for (i = 0; i < length; i++) cs = (uint8_t)(cs + node[i]);
    printf("mem node sig=\"%.3s\" len=%u rev=%u next=0x%08x checksum_sum=0x%02x (%s)\n",
           node, length, node[12], next, cs, cs == 0 ? "OK" : "FAIL");
    int count = node[18];
    for (i = 0; i < (uint32_t)count; i++) {
        uint8_t *e = node + 19 + i * 12;
        uint32_t t = e[0]|e[1]<<8|e[2]<<16|(uint32_t)e[3]<<24;
        uint32_t s = e[4]|e[5]<<8|e[6]<<16|(uint32_t)e[7]<<24;
        uint32_t z = e[8]|e[9]<<8|e[10]<<16|(uint32_t)e[11]<<24;
        printf("  map[%d] type=%u start=0x%08x size=0x%08x\n", i, t, s, z);
    }
    return cs == 0 ? 0 : 1;
}
