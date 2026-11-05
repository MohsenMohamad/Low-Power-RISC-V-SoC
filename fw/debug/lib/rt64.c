/*
 * 64-bit division helpers for clang builds: there is no libgcc for
 * riscv32-unknown-elf on a plain clang/lld host, so the runtime routines the
 * compiler emits for 64-bit '/' and '%' are provided here (shift-subtract).
 * Linked only with TOOLCHAIN=clang; the gcc build uses -lgcc.
 */
#include <stdint.h>

uint64_t __udivmoddi4(uint64_t n, uint64_t d, uint64_t *rem);
uint64_t __udivdi3(uint64_t n, uint64_t d);
uint64_t __umoddi3(uint64_t n, uint64_t d);
int64_t  __divdi3(int64_t n, int64_t d);
int64_t  __moddi3(int64_t n, int64_t d);

uint64_t __udivmoddi4(uint64_t n, uint64_t d, uint64_t *rem)
{
    uint64_t q = 0, r = 0;
    if (d == 0) { if (rem) *rem = n; return ~(uint64_t)0; }
    for (int i = 63; i >= 0; i--) {
        r = (r << 1) | ((n >> i) & 1u);
        if (r >= d) { r -= d; q |= (uint64_t)1 << i; }
    }
    if (rem) *rem = r;
    return q;
}

uint64_t __udivdi3(uint64_t n, uint64_t d) { return __udivmoddi4(n, d, 0); }
uint64_t __umoddi3(uint64_t n, uint64_t d) { uint64_t r; __udivmoddi4(n, d, &r); return r; }

int64_t __divdi3(int64_t n, int64_t d)
{
    int neg = (n < 0) != (d < 0);
    uint64_t q = __udivmoddi4(n < 0 ? -(uint64_t)n : (uint64_t)n, d < 0 ? -(uint64_t)d : (uint64_t)d, 0);
    return neg ? -(int64_t)q : (int64_t)q;
}

int64_t __moddi3(int64_t n, int64_t d)
{
    uint64_t r;
    __udivmoddi4(n < 0 ? -(uint64_t)n : (uint64_t)n, d < 0 ? -(uint64_t)d : (uint64_t)d, &r);
    return n < 0 ? -(int64_t)r : (int64_t)r;
}
