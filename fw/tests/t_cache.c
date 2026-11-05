/*
 * Validation: cache coherence with explicit maintenance.
 *
 * RAM is visible twice: cached (0x2000_0000) and uncached (0x3000_0000).
 * The uncached alias shows what actually is in RAM, i.e. what survives a
 * PD_CPU power-down and what another bus master would see.
 */
#include "test.h"
#include "drivers.h"
#include "platform_api.h"

#define CACHE_BYTES 4096u
#define CC_MISS()   REG32(CACHE_BASE + CACHE_DC_MISS)

static uint32_t buf[64] __attribute__((aligned(16)));
static uint32_t big[(2 * CACHE_BYTES + 2048) / 4] __attribute__((aligned(16)));

static int t_writeback(void)
{
    volatile uint32_t *c = buf;
    volatile uint32_t *u = UNCACHED(buf);
    cache_stats_t s0, s1;

    dcache_flush_range(buf, sizeof(buf));
    for (unsigned i = 0; i < 64; i++) u[i] = 0x11110000u + i;   /* RAM */
    dcache_inv_range(buf, sizeof(buf));
    for (unsigned i = 0; i < 64; i++) CHECK_EQ(c[i], 0x11110000u + i);
    for (unsigned i = 0; i < 64; i++) c[i] = 0x22220000u + i;   /* dirty lines */
    for (unsigned i = 0; i < 64; i++) CHECK_EQ(u[i], 0x11110000u + i); /* RAM unchanged */

    cache_stats(&s0);
    dcache_clean_range(buf, sizeof(buf));
    cache_stats(&s1);
    CHECK_EQ(s1.dwb - s0.dwb, sizeof(buf) / CACHE_LINE_SIZE);   /* one WB per line */
    for (unsigned i = 0; i < 64; i++) CHECK_EQ(u[i], 0x22220000u + i);

    /* clean keeps lines valid: reads hit */
    cache_stats(&s0);
    for (unsigned i = 0; i < 64; i++) CHECK_EQ(c[i], 0x22220000u + i);
    cache_stats(&s1);
    CHECK_EQ(s1.dmiss, s0.dmiss);
    return TEST_PASS;
}
TEST(30, "cache_writeback_clean", CAP_CACHE, t_writeback);

static int t_invalidate(void)
{
    volatile uint32_t *c = buf;
    volatile uint32_t *u = UNCACHED(buf);

    for (unsigned i = 0; i < 64; i++) c[i] = 0xA0000000u + i;
    dcache_clean_range(buf, sizeof(buf));
    for (unsigned i = 0; i < 64; i++) u[i] = 0xB0000000u + i;   /* RAM changes behind the cache */
    for (unsigned i = 0; i < 64; i++) CHECK_EQ(c[i], 0xA0000000u + i); /* stale copy */
    dcache_inv_range(buf, sizeof(buf));
    for (unsigned i = 0; i < 64; i++) CHECK_EQ(c[i], 0xB0000000u + i);

    /* invalidate discards dirty data */
    c[0] = 0xC0C0C0C0u;
    dcache_inv_range(buf, 4);
    CHECK_EQ(c[0], 0xB0000000u);
    CHECK_EQ(u[0], 0xB0000000u);

    /* flush = clean + invalidate */
    c[1] = 0xD1D1D1D1u;
    dcache_flush_range(&buf[1], 4);
    CHECK_EQ(u[1], 0xD1D1D1D1u);
    uint32_t m0 = CC_MISS();
    CHECK_EQ(c[1], 0xD1D1D1D1u);
    CHECK_EQ(CC_MISS(), m0 + 1);
    return TEST_PASS;
}
TEST(31, "cache_invalidate_flush_line", CAP_CACHE, t_invalidate);

static int t_eviction(void)
{
    volatile uint32_t *c = big;
    volatile uint32_t *u = UNCACHED(big);
    const unsigned n = 2 * CACHE_BYTES / 4;
    cache_stats_t s0, s1;

    dcache_flush_all();
    cache_stats(&s0);
    for (unsigned i = 0; i < n; i++) c[i] = i ^ 0x5EED0000u;    /* 2x capacity */
    cache_stats(&s1);
    printf_("    writes: miss %u, write-backs %u\n",
            (unsigned)(s1.dmiss - s0.dmiss), (unsigned)(s1.dwb - s0.dwb));
    CHECK(s1.dmiss - s0.dmiss >= n * 4 / CACHE_LINE_SIZE);
    CHECK(s1.dwb - s0.dwb >= CACHE_BYTES / CACHE_LINE_SIZE);    /* evictions wrote back */
    /* the first half was evicted: it must already be in RAM */
    for (unsigned i = 0; i < n / 2; i++) CHECK_EQ(u[i], i ^ 0x5EED0000u);
    dcache_flush_all();
    for (unsigned i = 0; i < n; i++) CHECK_EQ(u[i], i ^ 0x5EED0000u);

    /* LRU: three lines in one set (stride = sets * line = 2 KB) */
    volatile uint32_t *a = &big[0], *b = &big[512], *d = &big[1024];
    dcache_inv_range((const void *)&big[0], 2 * CACHE_BYTES + 16);
    uint32_t m0 = CC_MISS();
    (void)*a; (void)*b; (void)*a;          /* a = MRU, b = LRU */
    CHECK_EQ(CC_MISS() - m0, 2);
    (void)*d;                              /* evicts b          */
    CHECK_EQ(CC_MISS() - m0, 3);
    (void)*a;                              /* still cached      */
    CHECK_EQ(CC_MISS() - m0, 3);
    (void)*b;                              /* was evicted       */
    CHECK_EQ(CC_MISS() - m0, 4);
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
            if ((v & 63) == 0) { dcache_flush_range(cb + off, 4); maint++; }
            else if ((v & 63) == 1) { dcache_clean_range(cb + off, 4); maint++; }
            else if ((v & 255) == 2) { dcache_flush_all(); maint++; }
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
    dcache_flush_all();
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
    cache_sync_icache(code, 8);
    CHECK_EQ(fn(), 11);

    /* new code written and cleaned, but I$ not invalidated */
    cv[0] = li_a0(22);
    dcache_clean_range(code, 8);
    uint32_t stale = fn();
    printf_("    without I$ invalidate: %u (11 = stale line still cached)\n", (unsigned)stale);
    icache_inv_range(code, 8);
    CHECK_EQ(fn(), 22);

    /* I$ invalidated but D$ not cleaned: the fetch reads the old RAM copy */
    cv[0] = li_a0(33);
    icache_inv_range(code, 8);
    CHECK_EQ(fn(), 22);
    cache_sync_icache(code, 8);
    CHECK_EQ(fn(), 33);
    return TEST_PASS;
}
TEST(34, "cache_icache_coherence", CAP_CACHE, t_icache_smc);

static int t_disable_bypass(void)
{
    volatile uint32_t *c = buf;
    volatile uint32_t *u = UNCACHED(buf);
    cache_stats_t s0, s1;

    c[5] = 0x55667788u;                      /* dirty while enabled */
    dcache_enable(0);                        /* flushes, then bypass */
    CHECK_EQ(u[5], 0x55667788u);
    cache_stats(&s0);
    c[6] = 0x01020304u;
    CHECK_EQ(u[6], 0x01020304u);             /* write goes straight to RAM */
    u[7] = 0x0A0B0C0Du;
    CHECK_EQ(c[7], 0x0A0B0C0Du);
    cache_stats(&s1);
    CHECK_EQ(s1.dhit + s1.dmiss, s0.dhit + s0.dmiss);   /* cache not used */
    dcache_inv_all();
    dcache_enable(1);
    CHECK_EQ(cache_ctrl(), CACHE_CTRL_IC_EN | CACHE_CTRL_DC_EN);
    CHECK_EQ(c[6], 0x01020304u);
    return TEST_PASS;
}
TEST(35, "cache_disable_bypass", CAP_CACHE, t_disable_bypass);
