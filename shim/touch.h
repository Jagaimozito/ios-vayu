#pragma once
/* Boot-menu touch (guacamole): the S6SY761 on QUP wrapper 2 SE0, polled. touch.c */

/* Power the IC and take it out of reset; returns at once (it is ready ~300 ms later). 0 = started. */
int touch_begin(void);
/* -1: not (yet) usable; 0: no finger; 1: a finger at *x, *y (panel pixels, portrait 1440x3120). */
int touch_poll(int *x, int *y);
/* Before leaving the shim: the I2C engine idle and clean for the next owner (the kernel resets the IC). */
void touch_end(void);
