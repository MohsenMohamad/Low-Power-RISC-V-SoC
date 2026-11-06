/* Monitor commands shared by the applications (fw/app/app_cmds.c). */
#ifndef APP_CMDS_H
#define APP_CMDS_H

/* sleep <idle|sleep|deep> <ticks|uart>: succeeds only if the transition completed */
int cmd_sleep(int argc, char **argv);
/* opp <0..2> */
int cmd_opp(int argc, char **argv);
/* exit [code]: PASS / FAIL line, stop */
int cmd_exit(int argc, char **argv) __attribute__((noreturn));

#endif
