/*
 * Cache maintenance driver (4 KB 2-way I$ and write-back D$, 16 B lines).
 *
 * Command writes block until the operation is complete. After any power-up
 * the tag arrays hold garbage: cache_init() (INV_ALL) must run before the
 * caches are enabled, and FLUSH/CLEAN must not be used before that.
 */
#include "drivers.h"

#define CC(off) REG32(CACHE_BASE + (off))

static void line_op(uint32_t cmd_reg, uint32_t cmd, const void *p, uint32_t len)
{
    uintptr_t a   = (uintptr_t)p & ~(uintptr_t)(CACHE_LINE_SIZE - 1);
    uintptr_t end = (uintptr_t)p + len;
    for (; a < end; a += CACHE_LINE_SIZE) {
        CC(CACHE_LINE_ADDR) = (uint32_t)a;
        CC(cmd_reg) = cmd;
    }
}

void cache_init(void)
{
    CC(CACHE_CTRL) = 0;
    CC(CACHE_IC_CMD) = CACHE_CMD_INV_ALL;
    CC(CACHE_DC_CMD) = CACHE_CMD_INV_ALL;
    CC(CACHE_CTRL) = CACHE_CTRL_IC_EN | CACHE_CTRL_DC_EN;
}

void icache_enable(int en)
{
    uint32_t c = CC(CACHE_CTRL);
    CC(CACHE_CTRL) = en ? (c | CACHE_CTRL_IC_EN) : (c & ~CACHE_CTRL_IC_EN);
}

void dcache_enable(int en)
{
    uint32_t c = CC(CACHE_CTRL);
    if (!en && (c & CACHE_CTRL_DC_EN))
        CC(CACHE_DC_CMD) = CACHE_CMD_FLUSH_ALL;   /* write back before bypass */
    CC(CACHE_CTRL) = en ? (c | CACHE_CTRL_DC_EN) : (c & ~CACHE_CTRL_DC_EN);
}

uint32_t cache_ctrl(void)
{
    return CC(CACHE_CTRL);
}

void icache_inv_all(void)   { CC(CACHE_IC_CMD) = CACHE_CMD_INV_ALL; }
void dcache_inv_all(void)   { CC(CACHE_DC_CMD) = CACHE_CMD_INV_ALL; }
void dcache_clean_all(void) { CC(CACHE_DC_CMD) = CACHE_CMD_CLEAN_ALL; }
void dcache_flush_all(void) { CC(CACHE_DC_CMD) = CACHE_CMD_FLUSH_ALL; }

void dcache_clean_range(const void *p, uint32_t len) { line_op(CACHE_DC_CMD, CACHE_CMD_CLEAN_LINE, p, len); }
void dcache_inv_range(const void *p, uint32_t len)   { line_op(CACHE_DC_CMD, CACHE_CMD_INV_LINE, p, len); }
void dcache_flush_range(const void *p, uint32_t len) { line_op(CACHE_DC_CMD, CACHE_CMD_FLUSH_LINE, p, len); }
void icache_inv_range(const void *p, uint32_t len)   { line_op(CACHE_IC_CMD, CACHE_CMD_INV_LINE, p, len); }

void cache_sync_icache(const void *p, uint32_t len)
{
    dcache_clean_range(p, len);
    icache_inv_range(p, len);
}

void cache_stats(cache_stats_t *s)
{
    s->dhit  = CC(CACHE_DC_HIT);
    s->dmiss = CC(CACHE_DC_MISS);
    s->dwb   = CC(CACHE_DC_WB);
    s->ihit  = CC(CACHE_IC_HIT);
    s->imiss = CC(CACHE_IC_MISS);
}

void cache_stats_clear(void)
{
    CC(CACHE_DC_HIT) = 0;
    CC(CACHE_DC_MISS) = 0;
    CC(CACHE_DC_WB) = 0;
    CC(CACHE_IC_HIT) = 0;
    CC(CACHE_IC_MISS) = 0;
}
