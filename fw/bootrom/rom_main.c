/*
 * Boot ROM (doc/BOOT_ABI.md).
 *
 *  1. Install the ROM trap handler.
 *  2. Resume check, in this order; the first failing check makes it a cold
 *     boot and is recorded in handoff.boot_reason:
 *       PMU.STATUS.RESUME = 1            (else: power-on reset)
 *       PMU.SCRATCH1 = RESUME_MAGIC
 *       PMU.SCRATCH0 = CTX_ADDR
 *       ctx.magic = CTX_MAGIC, ctx.crc = CRC-32(ctx.regs, ctx.arch)
 *     The resume flags (W1C) and SCRATCH1 are cleared in every case, so a
 *     context is restored at most once. Resume: invalidate the context and
 *     restore it; execution continues inside the application's pm_suspend().
 *  3. Cold boot. Power-on: clear the handoff block and the persistent area
 *     (RAM content is undefined). A rejected resume keeps both. Check the
 *     application image header and CRC at APP_BASE; clean the D-cache,
 *     invalidate the I-cache and jump to the entry point. Without a valid
 *     image start the UART monitor.
 */
#include "handoff.h"
#include "drivers.h"
#include "arch.h"
#include "pm.h"
#include "lib.h"
#include "monitor.h"
#include "platform_api.h"

static const char *const cause_str[] = {"?", "POR", "SLEEP-WAKE", "DEEP-WAKE", "WATCHDOG"};
static const char *const reason_str[] = {"ok", "power-on", "bad resume magic", "bad context pointer",
                                         "bad context magic", "bad context CRC"};

static uint32_t resume_check(uint32_t status, const pm_ctx_t *ctx)
{
    if (!(status & PMU_ST_RESUME)) return REASON_NO_RESUME;
    if (pmu_read(PMU_SCRATCH1) != RESUME_MAGIC) return REASON_MAGIC;
    if (pmu_read(PMU_SCRATCH0) != CTX_ADDR) return REASON_POINTER;
    if (ctx->magic != CTX_MAGIC) return REASON_CTX_MAGIC;
    if (ctx->crc != pm_ctx_crc(ctx)) return REASON_CRC;
    return REASON_OK;
}

static int image_valid(const image_hdr_t *h)
{
    if (h->magic != IMAGE_MAGIC || h->version != IMAGE_VERSION || h->load_addr != APP_BASE) return 0;
    if (h->size < sizeof(*h) || h->size > RAM_BASE + RAM_SIZE - APP_BASE || (h->size & 3)) return 0;
    if (h->entry < APP_BASE + sizeof(*h) || h->entry >= APP_BASE + h->size || (h->entry & 3)) return 0;
    if (h->rsvd[0] || h->rsvd[1]) return 0;
    return crc32((const uint8_t *)h + sizeof(*h), h->size - sizeof(*h)) == h->crc;
}

void rom_main(void);
void rom_main(void)
{
    volatile handoff_t *ho = HANDOFF;
    pm_ctx_t *ctx = (pm_ctx_t *)CTX_ADDR;

    arch_init();

    uint32_t st     = pmu_status();
    uint32_t rc     = (st & PMU_ST_WDT_RST) ? RST_WDT :
                      !(st & PMU_ST_RESUME) ? RST_POR : (st & PMU_ST_RESUME_DEEP) ? RST_DEEP : RST_SLEEP;
    uint32_t reason = resume_check(st, ctx);
    pmu_clear_status(PMU_ST_RESUME | PMU_ST_RESUME_DEEP | PMU_ST_WDT_RST);
    pmu_write(PMU_SCRATCH1, 0);

    if (reason == REASON_OK) {
        ho->rst_cause   = rc;
        ho->boot_reason = REASON_OK;
        ho->pmu_status  = st;
        ho->boot_status = BOOT_RESUMED;
        ho->resumes     = ho->resumes + 1;
        ctx->magic      = 0;                    /* restored at most once */
        pm_ctx_restore(ctx);                    /* does not return */
    }

    if (rc == RST_POR) {
        /* RAM content is undefined after power-on (the host mailbox is the
         * host's and is left alone) */
        memset((void *)ho, 0, sizeof(*ho));
        volatile uint32_t *p = (volatile uint32_t *)(PERSIST_ADDR + RAM_UNCACHED_OFFSET);
        for (unsigned i = 0; i < PERSIST_SIZE / 4; i++) p[i] = 0;
        ho->boot_status = BOOT_COLD;
    } else if (rc == RST_WDT) {
        /* watchdog reset of PD_CPU (doc/SOC_REGMAP.md): RAM, the handoff block
         * and the persistent area are kept for the post-mortem */
        ho->boot_status = BOOT_COLD;
    } else {
        ho->bad_resumes = ho->bad_resumes + 1;
        ho->boot_status = BOOT_RESUME_BADCTX;
    }
    ctx->magic      = 0;
    ho->rom_version = ROM_VERSION;
    ho->rst_cause   = rc;
    ho->boot_reason = reason;
    ho->pmu_status  = st;
    ho->cold_boots  = ho->cold_boots + 1;

    platform_init();
    printf_("\n[ROM] LPSOC boot ROM %u.%u, reset cause %s%s%s\n",
            (unsigned)(ROM_VERSION >> 16), (unsigned)(ROM_VERSION & 0xFFFF), cause_str[rc],
            (rc != RST_POR && rc != RST_WDT) ? ", resume rejected: " : "",
            (rc != RST_POR && rc != RST_WDT) ? reason_str[reason] : "");

    const image_hdr_t *img = (const image_hdr_t *)APP_BASE;
    if (image_valid(img)) {
        printf_("[ROM] image at 0x%08x, %u bytes, entry 0x%08x\n",
                (unsigned)img->load_addr, (unsigned)img->size, (unsigned)img->entry);
        if (cache_sync_icache() == 0) {
            ((void (*)(void))(uintptr_t)img->entry)();
        }
        puts_("[ROM] D-cache write-back error\n");
    } else {
        puts_("[ROM] no valid image\n");
    }
    ho->boot_status = BOOT_NO_IMAGE;
    monitor_run(0, 0);
}
