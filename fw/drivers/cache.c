/* Cache maintenance through the CPU CSR mcachectl (0x7C0) only (doc/SPEC.md:
 * there is no memory-mapped cache controller). Supported operations: D-cache
 * clean, D-cache flush (clean + invalidate), I-cache invalidate. A CSR write
 * stalls until the operation completed, i.e. every write-back's AXI response
 * arrived; bit 31 then reports a write-back error, which is checked after
 * every clean and flush.
 *
 * Spike has no caches and no mcachectl: memory is coherent, only fence.i is
 * needed after writing code. */
#include "drivers.h"

#if PLATFORM_HAS_SOC
static uint32_t mcachectl(uint32_t cmd)
{
    uint32_t v;
    __asm__ volatile("csrw 0x7C0, %1\n\tcsrr %0, 0x7C0" : "=r"(v) : "r"(cmd) : "memory");
    return v;
}

int dcache_clean(void)
{
    return (mcachectl(MCACHECTL_DCLEAN) & MCACHECTL_WBERR) ? -1 : 0;
}

int dcache_flush(void)
{
    return (mcachectl(MCACHECTL_DFLUSH) & MCACHECTL_WBERR) ? -1 : 0;
}

void icache_invalidate(void)
{
    (void)mcachectl(MCACHECTL_IINVAL);
}

int cache_sync_icache(void)
{
    int r = dcache_clean();
    icache_invalidate();
    return r;
}
#else
int dcache_clean(void)  { __asm__ volatile("fence" ::: "memory"); return 0; }
int dcache_flush(void)  { __asm__ volatile("fence" ::: "memory"); return 0; }
void icache_invalidate(void) { __asm__ volatile("fence.i" ::: "memory"); }
int cache_sync_icache(void)  { __asm__ volatile("fence.i" ::: "memory"); return 0; }
#endif
