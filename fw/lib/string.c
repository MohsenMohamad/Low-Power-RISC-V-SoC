#include "lib.h"

void *memset(void *d, int c, size_t n)
{
    unsigned char *p = d;
    while (n--) *p++ = (unsigned char)c;
    return d;
}

void *memcpy(void *d, const void *s, size_t n)
{
    unsigned char *a = d;
    const unsigned char *b = s;
    while (n--) *a++ = *b++;
    return d;
}

void *memmove(void *d, const void *s, size_t n)
{
    unsigned char *a = d;
    const unsigned char *b = s;
    if (a < b) {
        while (n--) *a++ = *b++;
    } else {
        while (n--) a[n] = b[n];
    }
    return d;
}

int memcmp(const void *a, const void *b, size_t n)
{
    const unsigned char *x = a, *y = b;
    for (; n; n--, x++, y++)
        if (*x != *y) return *x - *y;
    return 0;
}

size_t strlen(const char *s)
{
    size_t n = 0;
    while (s[n]) n++;
    return n;
}

int strcmp(const char *a, const char *b)
{
    while (*a && *a == *b) { a++; b++; }
    return (unsigned char)*a - (unsigned char)*b;
}

int strncmp(const char *a, const char *b, size_t n)
{
    for (; n; n--, a++, b++) {
        if (*a != *b) return (unsigned char)*a - (unsigned char)*b;
        if (!*a) return 0;
    }
    return 0;
}

int parse_u32(const char *s, uint32_t *out)
{
    uint32_t v = 0;
    unsigned base = 10;
    if (!s || !*s) return -1;
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) { base = 16; s += 2; if (!*s) return -1; }
    for (; *s; s++) {
        unsigned d;
        if (*s >= '0' && *s <= '9') d = (unsigned)(*s - '0');
        else if (base == 16 && *s >= 'a' && *s <= 'f') d = (unsigned)(*s - 'a' + 10);
        else if (base == 16 && *s >= 'A' && *s <= 'F') d = (unsigned)(*s - 'A' + 10);
        else return -1;
        v = v * base + d;
    }
    *out = v;
    return 0;
}

uint32_t rand_next(uint32_t *state)
{
    uint32_t x = *state ? *state : 0x12345678u;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *state = x;
    return x;
}
