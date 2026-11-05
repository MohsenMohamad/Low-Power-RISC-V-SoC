/* Freestanding support library: console, formatting, strings, CRC-32. */
#ifndef LIB_H
#define LIB_H

#include <stdint.h>
#include <stddef.h>
#include <stdarg.h>

void   putch(char c);                    /* translates '\n' to "\r\n"   */
void   puts_(const char *s);
int    printf_(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
int    vprintf_(const char *fmt, va_list ap);
int    snprintf_(char *buf, size_t n, const char *fmt, ...) __attribute__((format(printf, 3, 4)));
int    getch_nb(void);                   /* -1 if none                   */

void  *memset(void *d, int c, size_t n);
void  *memcpy(void *d, const void *s, size_t n);
void  *memmove(void *d, const void *s, size_t n);
int    memcmp(const void *a, const void *b, size_t n);
size_t strlen(const char *s);
int    strcmp(const char *a, const char *b);
int    strncmp(const char *a, const char *b, size_t n);
int    parse_u32(const char *s, uint32_t *out);   /* dec or 0x-hex; 0 = ok */

uint32_t crc32_update(uint32_t crc, const void *p, size_t n);
uint32_t crc32(const void *p, size_t n);

/* xorshift32 pseudo random generator */
uint32_t rand_next(uint32_t *state);

#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))

#endif
