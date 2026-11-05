/* Common trap dispatch, shared by both CPU ports. */
#include "trap.h"
#include "arch.h"
#include "lib.h"
#include "platform_api.h"

static trap_handler_t exc_handler;
static trap_handler_t irq_handlers[16];
static volatile uint32_t ntraps;

static const char *cause_name(uint32_t c)
{
    switch (c) {
    case EXC_INSN_MISALIGNED:  return "instruction address misaligned";
    case EXC_INSN_FAULT:       return "instruction access fault";
    case EXC_ILLEGAL:          return "illegal instruction";
    case EXC_BREAKPOINT:       return "breakpoint";
    case EXC_LOAD_MISALIGNED:  return "load address misaligned";
    case EXC_LOAD_FAULT:       return "load access fault";
    case EXC_STORE_MISALIGNED: return "store address misaligned";
    case EXC_STORE_FAULT:      return "store access fault";
    case EXC_ECALL_M:          return "ecall from M-mode";
    default:                   return "?";
    }
}

static void fatal(trap_frame_t *f)
{
    printf_("\n*** FATAL TRAP: cause=0x%08x (%s) epc=0x%08x tval=0x%08x\n",
            (unsigned)f->cause, (f->cause & CAUSE_IRQ_FLAG) ? "unhandled interrupt"
                                                            : cause_name(f->cause),
            (unsigned)f->epc, (unsigned)f->tval);
    printf_("    ra=0x%08x sp=0x%08x\n", (unsigned)f->x[1], (unsigned)f->x[2]);
    platform_exit(0xFA000000u | (f->cause & 0xFFu));
}

trap_handler_t trap_set_exc_handler(trap_handler_t h)
{
    trap_handler_t old = exc_handler;
    exc_handler = h;
    return old;
}

trap_handler_t trap_set_irq_handler(uint32_t code, trap_handler_t h)
{
    trap_handler_t old = irq_handlers[code & 15];
    irq_handlers[code & 15] = h;
    return old;
}

uint32_t trap_count(void)
{
    return ntraps;
}

void trap_dispatch(trap_frame_t *f)
{
    ntraps++;
    if (f->cause & CAUSE_IRQ_FLAG) {
        trap_handler_t h = irq_handlers[f->cause & 15];
        if (h) h(f);
        else fatal(f);
    } else {
        if (exc_handler) exc_handler(f);
        else fatal(f);
    }
}
