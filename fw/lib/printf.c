/* Minimal printf: %d %i %u %x %X %p %s %c %%, flags '0' '-', width,
 * length modifiers l / ll (64-bit for ll). */
#include "lib.h"
#include "platform_api.h"

typedef struct {
    char  *buf;     /* NULL: console */
    size_t len;
    size_t pos;
} out_t;

static void out_c(out_t *o, char c)
{
    if (o->buf) {
        if (o->pos + 1 < o->len) o->buf[o->pos] = c;
    } else {
        putch(c);
    }
    o->pos++;
}

static void out_num(out_t *o, uint64_t v, unsigned base, int neg, int width,
                    int zero, int left, int upper)
{
    char tmp[24];
    int n = 0;
    const char *dig = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    do {
        tmp[n++] = dig[v % base];
        v /= base;
    } while (v);
    int len = n + (neg ? 1 : 0);
    if (!left && !zero) for (; width > len; width--) out_c(o, ' ');
    if (neg) out_c(o, '-');
    if (!left && zero) for (; width > len; width--) out_c(o, '0');
    while (n) out_c(o, tmp[--n]);
    if (left) for (; width > len; width--) out_c(o, ' ');
}

static int do_fmt(out_t *o, const char *f, va_list ap)
{
    for (; *f; f++) {
        if (*f != '%') { out_c(o, *f); continue; }
        f++;
        int zero = 0, left = 0, width = 0, lng = 0;
        for (;; f++) {
            if (*f == '0') zero = 1;
            else if (*f == '-') left = 1;
            else break;
        }
        while (*f >= '0' && *f <= '9') width = width * 10 + (*f++ - '0');
        while (*f == 'l') { lng++; f++; }
        switch (*f) {
        case 'd': case 'i': {
            int64_t v = lng >= 2 ? va_arg(ap, long long) : (int64_t)va_arg(ap, long);
            out_num(o, v < 0 ? (uint64_t)-v : (uint64_t)v, 10, v < 0, width, zero, left, 0);
            break;
        }
        case 'u': case 'x': case 'X': {
            uint64_t v = lng >= 2 ? va_arg(ap, unsigned long long) : (uint64_t)va_arg(ap, unsigned long);
            out_num(o, v, *f == 'u' ? 10 : 16, 0, width, zero, left, *f == 'X');
            break;
        }
        case 'p':
            out_c(o, '0'); out_c(o, 'x');
            out_num(o, (uintptr_t)va_arg(ap, void *), 16, 0, 8, 1, 0, 0);
            break;
        case 's': {
            const char *s = va_arg(ap, const char *);
            if (!s) s = "(null)";
            int l = (int)strlen(s);
            if (!left) for (; width > l; width--) out_c(o, ' ');
            while (*s) out_c(o, *s++);
            if (left) for (; width > l; width--) out_c(o, ' ');
            break;
        }
        case 'c': out_c(o, (char)va_arg(ap, int)); break;
        case '%': out_c(o, '%'); break;
        case 0: return (int)o->pos;
        default: out_c(o, '%'); out_c(o, *f); break;
        }
    }
    return (int)o->pos;
}

void putch(char c)
{
    if (c == '\n') platform_putc('\r');
    platform_putc(c);
}

void puts_(const char *s)
{
    while (*s) putch(*s++);
}

int getch_nb(void)
{
    return platform_getc();
}

int vprintf_(const char *fmt, va_list ap)
{
    out_t o = { 0, 0, 0 };
    return do_fmt(&o, fmt, ap);
}

int printf_(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    int n = vprintf_(fmt, ap);
    va_end(ap);
    return n;
}

int snprintf_(char *buf, size_t n, const char *fmt, ...)
{
    out_t o = { buf, n, 0 };
    va_list ap;
    va_start(ap, fmt);
    do_fmt(&o, fmt, ap);
    va_end(ap);
    if (n) buf[o.pos < n ? o.pos : n - 1] = 0;
    return (int)o.pos;
}
