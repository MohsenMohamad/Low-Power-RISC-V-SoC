#ifndef TRAP_H
#define TRAP_H

#include <stdint.h>

/* Layout shared with the assembly trap entries (arch/<cpu>/trap_entry.S). */
typedef struct trap_frame {
    uint32_t x[32];     /* x[0] unused, x[2] = sp at trap time            */
    uint32_t epc;       /* faulting / interrupted pc; written back on exit */
    uint32_t cause;     /* mcause encoding                                 */
    uint32_t tval;      /* mtval encoding                                  */
    uint32_t status;    /* mstatus                                         */
} trap_frame_t;

#define TRAP_FRAME_SIZE (36 * 4)

typedef void (*trap_handler_t)(trap_frame_t *f);

/* Handler for all synchronous exceptions; NULL restores the default
 * (fatal) handler. Returns the previous handler. */
trap_handler_t trap_set_exc_handler(trap_handler_t h);
/* Handler for one interrupt code (IRQ_MSI / IRQ_MTI / IRQ_MEI). */
trap_handler_t trap_set_irq_handler(uint32_t code, trap_handler_t h);

void trap_dispatch(trap_frame_t *f);    /* called by the arch entry code */
uint32_t trap_count(void);              /* traps taken since boot        */

#endif
