/*
 * DPI-C pseudo-terminal for the simulation UART bridge (dbg_uart_pty_bridge).
 * Opens a pty master in raw, non-blocking mode and prints/writes the slave
 * path so host tools (tools/bench) can open it like a serial port.
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

#ifdef __cplusplus
extern "C" {
#endif
int  dbg_pty_open(const char *path_file);
int  dbg_pty_getc(void);
void dbg_pty_putc(int c);
#ifdef __cplusplus
}
#endif

static int pty_fd = -1;

int dbg_pty_open(const char *path_file)
{
    struct termios t;
    pty_fd = posix_openpt(O_RDWR | O_NOCTTY);
    if (pty_fd < 0 || grantpt(pty_fd) || unlockpt(pty_fd)) {
        perror("[PTY] posix_openpt");
        return -1;
    }
    if (tcgetattr(pty_fd, &t) == 0) {
        cfmakeraw(&t);
        tcsetattr(pty_fd, TCSANOW, &t);
    }
    fcntl(pty_fd, F_SETFL, fcntl(pty_fd, F_GETFL) | O_NONBLOCK);
    const char *name = ptsname(pty_fd);
    printf("[PTY] UART on %s\n", name);
    fflush(stdout);
    if (path_file && path_file[0]) {
        FILE *f = fopen(path_file, "w");
        if (f) { fprintf(f, "%s\n", name); fclose(f); }
    }
    return 0;
}

/* -1 if no byte is available */
int dbg_pty_getc(void)
{
    unsigned char c;
    if (pty_fd < 0) return -1;
    ssize_t n = read(pty_fd, &c, 1);
    return n == 1 ? (int)c : -1;
}

void dbg_pty_putc(int c)
{
    unsigned char b = (unsigned char)c;
    if (pty_fd < 0) return;
    /* drop the byte if no client drains the pty (never block the simulation) */
    if (write(pty_fd, &b, 1) < 0 && errno != EAGAIN) { /* ignore */ }
}
