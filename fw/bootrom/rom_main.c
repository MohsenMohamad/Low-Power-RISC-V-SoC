/*
 * Boot ROM.
 *
 *  1. Install the ROM trap handler; invalidate and enable both caches (tag
 *     arrays are undefined after PD_CPU power-up).
 *  2. Read the PMU reset cause.
 *     - wake from SLEEP / DEEP_SLEEP: validate the saved context (magic +
 *       CRC-32). Valid -> restore it; execution continues inside the
 *       application's pm_suspend(). Invalid -> fall back to a cold boot.
 *     - POR: clear the handoff block and persistent area.
 *  3. Cold boot: check the application image header and CRC in RAM, jump to
 *     its entry point; without a valid image start the UART monitor.
 */
#include "handoff.h"
#include "drivers.h"
#include "arch.h"
#include "pm.h"
#include "lib.h"
#include "monitor.h"
#include "platform_api.h"

#define ROM_VERSION 0x00010000u    /* 1.0 */

static const char *cause_str(uint32_t rc)
{
    switch (rc) {
    case PMU_RC_POR:   return "POR";
    case PMU_RC_SLEEP: return "SLEEP-WAKE";
    case PMU_RC_DEEP:  return "DEEP-WAKE";
    case PMU_RC_SWRST: return "SW-RESET";
    default:           return "?";
    }
}

static int image_valid(const image_hdr_t *h)
{
    if (h->magic != IMAGE_MAGIC || h->load_addr != APP_BASE) return 0;
    if (h->size < sizeof(*h) || h->size > RAM_BASE + RAM_SIZE - APP_BASE) return 0;
    if (h->entry < APP_BASE || h->entry >= APP_BASE + h->size) return 0;
    return crc32((const uint8_t *)h + sizeof(*h), h->size - sizeof(*h)) == h->crc;
}

void rom_main(void);
void rom_main(void)
{
    volatile handoff_t *ho = HANDOFF;

    arch_init();
    cache_init();

    uint32_t rc = pmu_rst_cause();

    if (rc == PMU_RC_SLEEP || rc == PMU_RC_DEEP) {
        pm_ctx_t *ctx = (pm_ctx_t *)&ho->ctx;
        if (pm_ctx_valid(ctx)) {
            ho->rst_cause   = rc;
            ho->boot_status = BOOT_RESUMED;
            ho->resumes     = ho->resumes + 1;
            pm_ctx_restore(ctx);                /* does not return */
        }
        ho->bad_resumes = ho->bad_resumes + 1;
        ho->boot_status = BOOT_RESUME_BADCTX;
    } else if (rc == PMU_RC_POR) {
        /* RAM content is undefined after power-on */
        uint32_t keep = ho->soft_mtvec;
        memset((void *)ho, 0, sizeof(*ho));
        ho->soft_mtvec = keep;
        volatile uint32_t *p = UNCACHED((volatile uint32_t *)PERSIST_ADDR);
        for (unsigned i = 0; i < PERSIST_SIZE / 4; i++) p[i] = 0;
        ho->boot_status = BOOT_COLD;
    } else {
        ho->boot_status = BOOT_COLD;
    }
    ho->ctx.magic   = 0;
    ho->rst_cause   = rc;
    ho->rom_version = ROM_VERSION;
    ho->cold_boots  = ho->cold_boots + 1;

    platform_init();
    printf_("\n[ROM] LPSOC boot ROM %u.%u, reset cause %s%s\n",
            (unsigned)(ROM_VERSION >> 16), (unsigned)(ROM_VERSION & 0xFFFF), cause_str(rc),
            ho->boot_status == BOOT_RESUME_BADCTX ? " (saved context invalid, cold boot)" : "");

    const image_hdr_t *img = (const image_hdr_t *)APP_BASE;
    if (image_valid(img)) {
        printf_("[ROM] image at 0x%08x, %u bytes, entry 0x%08x\n",
                (unsigned)img->load_addr, (unsigned)img->size, (unsigned)img->entry);
        dcache_clean_all();
        icache_inv_all();
        ((void (*)(void))(uintptr_t)img->entry)();
    }
    ho->boot_status = BOOT_NO_IMAGE;
    puts_("[ROM] no valid image\n");
    monitor_run(0, 0);
}
