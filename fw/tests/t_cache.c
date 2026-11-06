/*
 * Validation: cache coherence with explicit maintenance through the CSR
 * mcachectl (doc/SPEC.md "Cache maintenance"; doc/CPU.md): D-cache clean,
 * D-cache flush (clean + invalidate), I-cache invalidate, write-back error
 * bit 31 (checked after every clean / flush).
 *
 * RAM is visible twice: cached (0x1000_0000) and uncached (0x3000_0000). The
 * uncached alias shows what actually is in RAM, i.e. what survives a PD_CPU
 * power-down and what another bus master would see.
 *
 * Operations the hardware does not have (line operations, dirty-discarding
 * invalidate, cache disable / bypass; audit B07, W20) are not tested; their
 * observable effects are checked functionally instead (clean keeps lines
 * valid, LRU replacement, eviction write-back). Hit / miss statistics come
 * from the debug event counters (test 37).
 */
#include "test.h"
#include "drivers.h"
#include "platform_api.h"

#define SET_STRIDE (CACHE_SIZE / CACHE_WAYS)        /* 2 KB: same set index */

static uint32_t buf[64] __attribute__((aligned(16)));
static uint32_t big[(2 * CACHE_SIZE + 2048) / 4] __attribute__((aligned(16)));

static int t_writeback(void)
{
    volatile uint32_t *c = buf;
    volatile uint32_t *u = UNCACHED(buf);

    CHECK_EQ(dcache_flush(), 0);
    for (unsigned i = 0; i < 64; i++) u[i] = 0x11110000u + i;   /* RAM */
    for (unsigned i = 0; i < 64; i++) CHECK_EQ(c[i], 0x11110000u + i);   /* refilled */
    for (unsigned i = 0; i < 64; i++) c[i] = 0x22220000u + i;   /* dirty lines */
    for (unsigned i = 0; i < 64; i++) CHECK_EQ(u[i], 0x11110000u + i); /* RAM unchanged */

    CHECK_EQ(dcache_clean(), 0);
    for (unsigned i = 0; i < 64; i++) CHECK_EQ(u[i], 0x22220000u + i);  /* written back */

    /* clean keeps lines valid: RAM changed behind the cache is not seen */
    for (unsigned i = 0; i < 64; i++) u[i] = 0x33330000u + i;
    for (unsigned i = 0; i < 64; i++) CHECK_EQ(c[i], 0x22220000u + i);
    CHECK_EQ(dcache_flush(), 0);
    /* the lines were clean: the flush must not write the stale copy back */
    for (unsigned i = 0; i < 64; i++) CHECK_EQ(u[i], 0x33330000u + i);
    for (unsigned i = 0; i < 64; i++) CHECK_EQ(c[i], 0x33330000u + i);
    return TEST_PASS;
}
TEST(30, "cache_writeback_clean", CAP_CACHE, t_writeback);

static int t_flush(void)
{
    volatile uint32_t *c = buf;
    volatile uint32_t *u = UNCACHED(buf);

    for (unsigned i = 0; i < 64; i++) c[i] = 0xA0000000u + i;
    CHECK_EQ(dcache_clean(), 0);
    for (unsigned i = 0; i < 64; i++) u[i] = 0xB0000000u + i;   /* RAM changes behind the cache */
    for (unsigned i = 0; i < 64; i++) CHECK_EQ(c[i], 0xA0000000u + i); /* stale copy */
    CHECK_EQ(dcache_flush(), 0);                                /* invalidates */
    for (unsigned i = 0; i < 64; i++) CHECK_EQ(c[i], 0xB0000000u + i);

    /* flush = clean + invalidate: dirty data reaches RAM, then refills */
    c[1] = 0xD1D1D1D1u;
    CHECK_EQ(u[1], 0xB0000001u);
    CHECK_EQ(dcache_flush(), 0);
    CHECK_EQ(u[1], 0xD1D1D1D1u);
    u[1] = 0xE2E2E2E2u;
    CHECK_EQ(c[1], 0xE2E2E2E2u);                                /* not cached any more */
    return TEST_PASS;
}
TEST(31, "cache_flush_invalidate", CAP_CACHE, t_flush);

static int t_eviction(void)
{
    volatile uint32_t *c = big;
    volatile uint32_t *u = UNCACHED(big);
    const unsigned n = 2 * CACHE_SIZE / 4;

    CHECK_EQ(dcache_flush(), 0);
    for (unsigned i = 0; i < n; i++) u[i] = 0;
    for (unsigned i = 0; i < n; i++) c[i] = i ^ 0x5EED0000u;    /* 2x capacity */
    /* the first half was evicted (write-back, no maintenance): already in RAM */
    for (unsigned i = 0; i < n / 2; i++) CHECK_EQ(u[i], i ^ 0x5EED0000u);
    unsigned dirty = 0;
    for (unsigned i = n / 2; i < n; i++) dirty += (u[i] != (i ^ 0x5EED0000u));
    printf_("    after 2x capacity writes: %u of %u words of the second half only in the D-cache\n",
            dirty, n / 2);
    CHECK(dirty > 0);
    CHECK_EQ(dcache_flush(), 0);
    for (unsigned i = 0; i < n; i++) CHECK_EQ(u[i], i ^ 0x5EED0000u);

    /* LRU: three lines in one set (stride = sets * line = 2 KB). The evicted
     * line is the least recently used one; its dirty data reaches RAM. */
    volatile uint32_t *a = &big[0], *b = &big[SET_STRIDE / 4], *d = &big[2 * SET_STRIDE / 4];
    volatile uint32_t *ua = &u[0], *ub = &u[SET_STRIDE / 4];
    CHECK_EQ(dcache_flush(), 0);
    *a = 0xAAAA0001u;                        /* a dirty                 */
    *b = 0xBBBB0001u;                        /* b dirty, a = LRU        */
    (void)*a;                                /* a = MRU, b = LRU        */
    (void)*d;                                /* evicts b                */
    CHECK_EQ(*ub, 0xBBBB0001u);              /* b written back          */
    CHECK(*ua != 0xAAAA0001u);               /* a still only cached     */
    (void)*b;                                /* refill b: evicts LRU a  */
    CHECK_EQ(*ua, 0xAAAA0001u);
    CHECK_EQ(*a, 0xAAAA0001u);
    CHECK_EQ(*b, 0xBBBB0001u);
    CHECK_EQ(dcache_flush(), 0);
    return TEST_PASS;
}
TEST(32, "cache_eviction_lru", CAP_CACHE, t_eviction);

/* Random traffic against a reference model: every access is applied to a
 * cached buffer and to an uncached shadow; reads must match at all times and
 * RAM must equal the shadow after a final flush. */
static int t_random_ref(void)
{
    const unsigned words = 1536;              /* 6 KB > cache size */
    uint8_t *cb = (uint8_t *)big;
    static uint32_t shadow_mem[1536] __attribute__((aligned(16)));
    volatile uint8_t *sm = (volatile uint8_t *)UNCACHED(shadow_mem);
    uint32_t seed = 0xC0FFEE11u;
    unsigned nops = 6000, maint = 0;

    for (unsigned i = 0; i < words; i++) {
        ((volatile uint32_t *)cb)[i] = i;
        ((volatile uint32_t *)sm)[i] = i;
    }
    for (unsigned k = 0; k < nops; k++) {
        uint32_t r = rand_next(&seed);
        uint32_t off = (r >> 8) % (words * 4);
        uint32_t v = rand_next(&seed);
        switch (r & 15) {
        case 0: case 1: case 2:
            off &= ~3u;
            *(volatile uint32_t *)(cb + off) = v; *(volatile uint32_t *)(sm + off) = v; break;
        case 3: case 4:
            off &= ~1u;
            *(volatile uint16_t *)(cb + off) = (uint16_t)v; *(volatile uint16_t *)(sm + off) = (uint16_t)v; break;
        case 5: case 6:
            *(volatile uint8_t *)(cb + off) = (uint8_t)v; *(volatile uint8_t *)(sm + off) = (uint8_t)v; break;
        case 7:
            if ((v & 127) == 0) { CHECK_EQ(dcache_clean(), 0); maint++; }
            else if ((v & 127) == 1) { CHECK_EQ(dcache_flush(), 0); maint++; }
            break;
        default: {
            off &= ~3u;
            uint32_t x = *(volatile uint32_t *)(cb + off);
            uint32_t y = *(volatile uint32_t *)(sm + off);
            if (x != y) {
                printf_("    op %u: [0x%x] cache 0x%08x model 0x%08x\n", k, (unsigned)off, (unsigned)x, (unsigned)y);
                CHECK(x == y);
            }
        }
        }
    }
    CHECK_EQ(dcache_flush(), 0);
    volatile uint32_t *ram = UNCACHED(big);
    for (unsigned i = 0; i < words; i++) CHECK_EQ(ram[i], ((volatile uint32_t *)sm)[i]);
    printf_("    %u random ops, %u maintenance ops\n", nops, maint);
    return TEST_PASS;
}
TEST(33, "cache_random_vs_model", CAP_CACHE, t_random_ref);

typedef uint32_t (*fn_t)(void);
static uint32_t code[8] __attribute__((aligned(16)));

static uint32_t li_a0(uint32_t k) { return 0x00000513u | (k << 20); }   /* addi a0, x0, k */

static int t_icache_smc(void)
{
    volatile uint32_t *cv = code;
    fn_t fn = (fn_t)(uintptr_t)code;

    cv[0] = li_a0(11); cv[1] = 0x00008067u;  /* ret */
    CHECK_EQ(cache_sync_icache(), 0);
    CHECK_EQ(fn(), 11);

    /* new code written and cleaned, but I$ not invalidated */
    cv[0] = li_a0(22);
    CHECK_EQ(dcache_clean(), 0);
    uint32_t stale = fn();
    printf_("    without I$ invalidate: %u (11 = stale line still cached)\n", (unsigned)stale);
    CHECK_EQ(stale, 11);
    icache_invalidate();
    CHECK_EQ(fn(), 22);

    /* I$ invalidated but D$ not cleaned: the fetch reads the old RAM copy */
    cv[0] = li_a0(33);
    icache_invalidate();
    CHECK_EQ(fn(), 22);
    CHECK_EQ(cache_sync_icache(), 0);
    CHECK_EQ(fn(), 33);

    /* fence.i cleans the D-cache and invalidates the I-cache (doc/CPU.md) */
    cv[0] = li_a0(44);
    __asm__ volatile("fence.i" ::: "memory");
    CHECK_EQ(fn(), 44);
    return TEST_PASS;
}
TEST(34, "cache_icache_coherence", CAP_CACHE, t_icache_smc);

/* The uncached alias (doc/SPEC.md, audit B02): same physical RAM, bypasses the
 * D-cache, byte strobes for partial stores. */
static int t_alias(void)
{
    volatile uint32_t *c = buf;
    volatile uint32_t *u = UNCACHED(buf);
    volatile uint8_t  *ub = (volatile uint8_t *)u;
    volatile uint16_t *uh = (volatile uint16_t *)u;

    CHECK_EQ((uintptr_t)u - (uintptr_t)c, RAM_UNCACHED_OFFSET);
    CHECK_EQ((uintptr_t)u >> 28, 0x3u);
    CHECK_EQ(dcache_flush(), 0);
    u[0] = 0x01020304u;
    CHECK_EQ(c[0], 0x01020304u);             /* same physical word        */
    c[0] = 0x55667788u;                      /* dirty in the D-cache      */
    CHECK_EQ(u[0], 0x01020304u);             /* alias sees RAM, not cache */
    ub[4] = 0x11; ub[5] = 0x22; ub[6] = 0x33; ub[7] = 0x44;   /* byte strobes */
    CHECK_EQ(u[1], 0x44332211u);
    uh[5] = 0xBEEF;                          /* halfword strobes          */
    CHECK_EQ(u[2] >> 16, 0xBEEFu);
    CHECK_EQ(ub[6], 0x33u);
    CHECK_EQ(uh[3], 0x4433u);
    CHECK_EQ(dcache_clean(), 0);
    CHECK_EQ(u[0], 0x55667788u);
    /* the end of the RAM window maps to the end of the alias window (read
     * only: the top of RAM is the stack) */
    volatile uint32_t *last_c = (volatile uint32_t *)(RAM_BASE + RAM_SIZE - 4);
    volatile uint32_t *last_u = UNCACHED(last_c);
    CHECK_EQ(dcache_clean(), 0);
    uint32_t x = *last_u, y = *last_c;
    CHECK_EQ(x, y);
    return TEST_PASS;
}
TEST(35, "cache_uncached_alias", CAP_CACHE, t_alias);

/* mcachectl: bit 31 (write-back error) reads 0 after successful operations,
 * reserved bits read 0, an I-cache invalidate leaves dirty D-cache data. */
static int t_mcachectl(void)
{
    volatile uint32_t *c = buf;
    volatile uint32_t *u = UNCACHED(buf);
    uint32_t v;
    __asm__ volatile("csrr %0, 0x7C0" : "=r"(v));
    CHECK_EQ(v, 0);
    c[9] = 0x0BADF00Du;
    icache_invalidate();
    CHECK(u[9] != 0x0BADF00Du);              /* I-invalidate does not clean D */
    __asm__ volatile("csrwi 0x7C0, 4\n\tcsrr %0, 0x7C0" : "=r"(v) :: "memory");
    CHECK_EQ(v, 0);                          /* clean completed without error */
    CHECK_EQ(u[9], 0x0BADF00Du);
    CHECK_EQ(dcache_flush(), 0);
    return TEST_PASS;
}
TEST(36, "cache_mcachectl_csr", CAP_CACHE, t_mcachectl);

/* Cache statistics (doc/SPEC.md "Cache maintenance": they come from the debug
 * event counters, drivers/dbg.c cache_stats()). Exact D-cache counts: after
 * a flush, one load to each of 32 distinct lines is 32 misses, the same loads
 * again 32 hits; a store to a resident line is a hit, uncached loads through
 * the alias count as neither. The measured loops make no other cacheable
 * data access (cache_stats reads uncached registers). I-cache: an invalidate
 * is followed by misses, a loop that fits the cache then only hits. */
#if PLATFORM_HAS_SOC
#define ST_LINES 32u
static uint32_t st_buf[ST_LINES * 4] __attribute__((aligned(16)));

/* Counter snapshots go to registers only: drivers/dbg.c's dbg_evcnt_get and
 * dbg_evcnt_settle are leaf functions without stack accesses, so the
 * measurement itself adds no cacheable data access. */
#define SNAP(h, m) do { dbg_evcnt_settle();                         \
        (h) = dbg_evcnt_get(EVC_DC_HIT); (m) = dbg_evcnt_get(EVC_DC_MISS); } while (0)

static int t_cache_stats(void)
{
    volatile uint32_t *p = st_buf, *u = UNCACHED(st_buf);
    uint32_t h0, m0, h1, m1, sum = 0;
    CHECK(dbg_present());
    CHECK(dcache_flush() == 0);
    SNAP(h0, m0);
    for (uint32_t i = 0; i < ST_LINES; i++) sum += p[i * 4];          /* 32 cold lines */
    SNAP(h1, m1);
    CHECK_EQ(m1 - m0, ST_LINES);
    CHECK_EQ(h1 - h0, 0);
    SNAP(h0, m0);
    for (uint32_t i = 0; i < ST_LINES; i++) sum += p[i * 4 + 1];      /* resident: hits */
    SNAP(h1, m1);
    CHECK_EQ(h1 - h0, ST_LINES);
    CHECK_EQ(m1 - m0, 0);
    SNAP(h0, m0);
    for (uint32_t i = 0; i < ST_LINES; i++) p[i * 4 + 2] = i;         /* store hits */
    SNAP(h1, m1);
    CHECK_EQ(h1 - h0, ST_LINES);
    CHECK_EQ(m1 - m0, 0);
    SNAP(h0, m0);
    for (uint32_t i = 0; i < ST_LINES; i++) sum += u[i * 4];          /* uncached: neither */
    SNAP(h1, m1);
    CHECK_EQ(h1 - h0, 0);
    CHECK_EQ(m1 - m0, 0);
    (void)sum;
    /* I-cache: misses after an invalidate, a resident loop only hits */
    dbg_evcnt_settle();
    h0 = dbg_evcnt_get(EVC_IC_HIT); m0 = dbg_evcnt_get(EVC_IC_MISS);
    icache_invalidate();
    for (volatile int i = 0; i < 64; i++) { }
    dbg_evcnt_settle();
    h1 = dbg_evcnt_get(EVC_IC_HIT); m1 = dbg_evcnt_get(EVC_IC_MISS);
    CHECK(m1 > m0);
    h0 = h1; m0 = m1;
    for (volatile int i = 0; i < 64; i++) { }
    dbg_evcnt_settle();
    h1 = dbg_evcnt_get(EVC_IC_HIT); m1 = dbg_evcnt_get(EVC_IC_MISS);
    CHECK(h1 - h0 > 64u);
    CHECK(m1 - m0 < 8u);
    /* the statistics API returns exactly the event counters (held for the read) */
    cache_stats_t cs;
    dbg_evcnt_ctrl(1, 0);
    dbg_evcnt_settle();
    cache_stats(&cs);
    CHECK_EQ(cs.dc_hit, dbg_evcnt_get(EVC_DC_HIT));
    CHECK_EQ(cs.dc_miss, dbg_evcnt_get(EVC_DC_MISS));
    CHECK_EQ(cs.ic_hit, dbg_evcnt_get(EVC_IC_HIT));
    CHECK_EQ(cs.ic_miss, dbg_evcnt_get(EVC_IC_MISS));
    dbg_evcnt_ctrl(0, 0);
    CHECK(dcache_clean() == 0);
    return TEST_PASS;
}
#else
static int t_cache_stats(void) { return TEST_SKIP; }      /* CAP_CACHE: never run */
#endif
TEST(37, "cache_stats_counters", CAP_CACHE, t_cache_stats);
