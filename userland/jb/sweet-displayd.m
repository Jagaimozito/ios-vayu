/*
 * sweet-displayd: iOS's brightness slider and Night Shift, applied by the display controller's colour-correction
 * stage (DSPP0/1 PCC, as userland/jb/dispcolor.c; /dev/pmem, root, kernel 0094+, boot-arg sweetpmem=1).
 *
 * There is no display driver: the bootloader's continuous splash scans the framebuffer out by itself, and the fake
 * IOMobileFramebuffer gets no brightness or colour calls from CoreBrightness (2026-11-09: only selectors 4/5/6/12/79
 * while the slider moved and Night Shift toggled). So this reads what iOS has decided instead, several times a second:
 *   brightness   BKSDisplayBrightnessGetCurrent() (BackBoardServices, 0.0 - 1.0: the slider)
 *   Night Shift  -[CBBlueLightClient getBlueLightStatus:] (byte 0 = active now) and -getStrength: (0.0 - 1.0)
 * and writes the PCC matrix when either changes. AMOLED: scaling the pixels is less light from the panel.
 *
 *   sweet-displayd           run (launchd job com.sweet.displayd, or by hand in the background)
 *   sweet-displayd -v        also print every change
 *   sweet-displayd -1        print what iOS says once and exit (writes nothing)
 * macOS 27 (2026-11-22, built by userland/build-macos.sh): the slider is DisplayServices' brightness of the main
 * display (Control Center, the brightness keys) instead of BackBoardServices; Night Shift is the same
 * CBBlueLightClient. Everything below the "what the OS has decided" part is shared.
 * MIT, as userland/.
 */
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <TargetConditionals.h>
#if TARGET_OS_OSX
#include <libproc.h>
#include <pthread.h>
#include <stdlib.h>
#endif

/* ---- the display controller (see dispcolor.c for the probe this rests on) ---- */
#define MDP             0x0ae01000ull
#define CTL0            (MDP + 0x1000)
#define CTL_FLUSH       0x018
#define CTL_INTF_ACTIVE 0x0f4
#define LM(n)           (MDP + 0x44000 + 0x1000 * (n))
#define DSPP(n)         (MDP + 0x54000 + 0x2000 * (n))
#define PCC             0x1700

static int pmem = -1;

static uint32_t rd(uint64_t pa)
{
	uint32_t v = 0xdeadbeef;
	return pread(pmem, &v, 4, (off_t)pa) == 4 ? v : 0xdeadbeef;
}

static bool wr(uint64_t pa, uint32_t v)
{
	return pwrite(pmem, &v, 4, (off_t)pa) == 4;
}

static bool controller_as_probed(void)
{
	return (rd(MDP) & 0xffff0000) == 0x50000000 && rd(CTL0 + CTL_INTF_ACTIVE) == 0x2 &&
	    rd(LM(0) + 4) == 0x0c3002d0 && rd(LM(1) + 4) == 0x0c3002d0;
}

static uint32_t coeff(double v)
{
	v = v < 0 ? 0 : v > 2 ? 2 : v;
	return (uint32_t)(v * 32768.0 + 0.5) & 0x3ffff;
}

/* r, g, b scale; all 1: PCC off (the picture exactly as drawn) */
static bool apply(double r, double g, double b)
{
	static bool said;
	if (!controller_as_probed()) {
		if (!said) {
			fprintf(stderr, "sweet-displayd: the display controller is not as probed: nothing written\n");
			said = true;
		}
		return false;
	}
	bool identity = r >= 0.999 && g >= 0.999 && b >= 0.999;
	for (int n = 0; n < 2; n++) {
		uint64_t p = DSPP(n) + PCC;
		if (identity) {
			wr(p, 0);
			continue;
		}
		wr(p + 0x10, coeff(r)); wr(p + 0x1c, 0); wr(p + 0x28, 0);
		wr(p + 0x14, 0); wr(p + 0x20, coeff(g)); wr(p + 0x2c, 0);
		wr(p + 0x18, 0); wr(p + 0x24, 0); wr(p + 0x30, coeff(b));
		wr(p, 1);
	}
	return wr(CTL0 + CTL_FLUSH, (1u << 13) | (1u << 14));
}

/*
 * ---- the panel's own brightness (as userland/jb/panelbright.c; user-tested 2026-11-09: 1 = dimmest, 1023 = brightest,
 * colours intact) ----
 * DCS long write 0x51 hi lo over DSI0 (0x0ae94000), command mode, embedded DMA from a buffer just past the splash
 * frame (0x9d124000). The bootloader leaves it at 184.
 */
#define DSI0            0x0ae94000ull
#define DSI_CTRL        0x004
#define DSI_CMD_DMA_CTRL 0x03c
#define DSI_DMA_BASE    0x048
#define DSI_DMA_LEN     0x04c
#define DSI_TRIG_CTRL   0x084
#define DSI_TRIG_DMA    0x090
#define DSI_INTR_CTRL   0x110
#define DSI_BUF         0x9d124000ull

static bool panel_brightness(unsigned level)
{
	static bool said;
	uint32_t ver = rd(DSI0), ctrl = rd(DSI0 + DSI_CTRL);
	if ((ver >> 24) != 0x20 || !(ctrl & 1) || !(ctrl & 6)) {
		if (!said) {
			fprintf(stderr, "sweet-displayd: DSI0 not as probed (version %08x, CTRL %08x): no panel brightness\n", ver, ctrl);
			said = true;
		}
		return false;
	}
	if (level < 1)
		level = 1;
	if (level > 1023)
		level = 1023;
	/* header: WC 3, DCS long write 0x39, last + long; payload 0x51 hi lo, 0xff */
	wr(DSI_BUF, 0xc0390003u);
	wr(DSI_BUF + 4, 0xff000051u | (level >> 8 & 0xff) << 8 | (level & 0xff) << 16);
	uint32_t dma_ctrl = rd(DSI0 + DSI_CMD_DMA_CTRL), trig = rd(DSI0 + DSI_TRIG_CTRL);
	wr(DSI0 + DSI_INTR_CTRL, rd(DSI0 + DSI_INTR_CTRL) | 1);
	wr(DSI0 + DSI_CTRL, ctrl | 4);
	wr(DSI0 + DSI_CMD_DMA_CTRL, (dma_ctrl & ~((1u << 31) | (1u << 30) | (1u << 26))) | (1u << 28));
	if ((trig & 7) != 4)
		wr(DSI0 + DSI_TRIG_CTRL, (trig & ~7u) | 4);
	wr(DSI0 + DSI_DMA_BASE, (uint32_t)DSI_BUF);
	wr(DSI0 + DSI_DMA_LEN, 8);
	wr(DSI0 + DSI_TRIG_DMA, 1);
	bool done = false;
	for (int i = 0; i < 500 && !(done = rd(DSI0 + DSI_INTR_CTRL) & 1); i++)
		usleep(200);                    /* at most 100 ms: it goes between two frames */
	wr(DSI0 + DSI_INTR_CTRL, rd(DSI0 + DSI_INTR_CTRL) | 1);
	if ((trig & 7) != 4)
		wr(DSI0 + DSI_TRIG_CTRL, trig);
	wr(DSI0 + DSI_CMD_DMA_CTRL, dma_ctrl);
	wr(DSI0 + DSI_CTRL, ctrl);
	return done;
}

/* ---- what iOS has decided ---- */
static float (*BKSDisplayBrightnessGetCurrent)(void);
#if TARGET_OS_OSX
/* DisplayServices (private): the brightness Control Center and the keys set, 0.0 - 1.0 */
static int (*DisplayServicesGetBrightness)(uint32_t display, float *brightness);
static bool (*DisplayServicesCanChangeBrightness)(uint32_t display);
extern uint32_t CGMainDisplayID(void);
static float macos_brightness(void)
{
	float b = 1.0f;
	if (DisplayServicesGetBrightness && DisplayServicesGetBrightness(CGMainDisplayID(), &b) != 0)
		b = 1.0f;
	return b;
}

/*
 * 2026-11-23: brightness control gone after a reboot. corebrightnessd (the built-in display's brightness handler)
 * started before WindowServer ("SkyLight: Server root port lookup error - bootstrap: unknown service"), so it never
 * registered with it: WindowServer "Display 1, no brightness handler registered", DisplayServicesCanChangeBrightness
 * false, no slider. Restarting corebrightnessd by hand fixed it. So: once WindowServer has been running for a few
 * seconds and the display still cannot change brightness, restart corebrightnessd (launchd starts it again). Two tries
 * during the login window were not enough (it registered only when restarted after login), so it keeps trying every
 * 20 s while brightness cannot change, up to 15 times. Runs on its own thread; the main loop does not wait for it.
 */
static bool process_running(const char *name)
{
	int n = proc_listallpids(NULL, 0);
	if (n <= 0)
		return false;
	pid_t *pids = calloc((size_t)n + 64, sizeof(pid_t));
	if (pids == NULL)
		return false;
	n = proc_listallpids(pids, (int)(((size_t)n + 64) * sizeof(pid_t)));
	bool found = false;
	for (int i = 0; i < n && !found; i++) {
		char pname[64] = "";
		if (pids[i] > 0 && proc_name(pids[i], pname, sizeof(pname)) > 0 && !strcmp(pname, name))
			found = true;
	}
	free(pids);
	return found;
}

static void *corebrightness_kick(void *arg)
{
	(void)arg;
	int ws_up = 0, kicks = 0;
	for (int t = 0; t < 900 && kicks < 15; t++) {        /* every 2 s for up to 30 minutes */
		sleep(2);
		if (DisplayServicesCanChangeBrightness(CGMainDisplayID())) {
			if (t > 0 || kicks > 0)
				fprintf(stderr, "sweet-displayd: DisplayServices now says the main display can change brightness\n");
			return NULL;
		}
		if (!process_running("WindowServer")) {
			ws_up = 0;
			continue;
		}
		if (++ws_up < 3)                                /* WindowServer up for about 6 s */
			continue;
		kicks++;
		fprintf(stderr, "sweet-displayd: no brightness handler with WindowServer up: restarting corebrightnessd (%d)\n", kicks);
		system("/usr/bin/killall corebrightnessd");
		ws_up = -7;                                     /* give the new one about 20 s before trying again */
	}
	return NULL;
}
#endif
static id blueLight;

static uint8_t last_status[128];

static bool night_shift(bool *active, float *strength)
{
	if (blueLight == nil)
		return false;
	uint8_t status[128] = { 0 };    /* CBBlueLightClient's StatusData: active, enabled, sunSchedulePermitted, ... */
	BOOL ok = ((BOOL (*)(id, SEL, void *))objc_msgSend)(blueLight, sel_registerName("getBlueLightStatus:"), status);
	float s = 0;
	if ([blueLight respondsToSelector:sel_registerName("getStrength:")])
		((BOOL (*)(id, SEL, float *))objc_msgSend)(blueLight, sel_registerName("getStrength:"), &s);
	/*
	 * byte 0 "active", byte 1 "enabled": Night Shift tools on macOS take "enabled" as on. With no display hardware
	 * CoreBrightness may never mark it active (2026-11-09: brightness followed, Night Shift did not): either counts.
	 */
	/*
	 * With 0197 (AppleARMBacklight) CoreBrightness answers. User's -1 runs, 02:22 inside a 22:00-07:00 schedule:
	 * on = 01 01 ..., switched off in Control Center = 01 00 ...: byte 0 (active) is "inside the scheduled hours",
	 * byte 1 (enabled) is whether Night Shift is on now (the schedule turns it on, the toggle overrides). Byte 1.
	 */
	*active = ok && status[1];
	*strength = s;
	memcpy(last_status, status, sizeof(last_status));
	return ok;
}

int main(int argc, char **argv)
{
	@autoreleasepool {
		bool verbose = argc > 1 && !strcmp(argv[1], "-v"), once = argc > 1 && !strcmp(argv[1], "-1");

#if TARGET_OS_OSX
		void *ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW);
		DisplayServicesGetBrightness = ds ? (int (*)(uint32_t, float *))dlsym(ds, "DisplayServicesGetBrightness") : NULL;
		DisplayServicesCanChangeBrightness = ds ? (bool (*)(uint32_t))dlsym(ds, "DisplayServicesCanChangeBrightness") : NULL;
		BKSDisplayBrightnessGetCurrent = DisplayServicesGetBrightness ? macos_brightness : NULL;
		if (DisplayServicesCanChangeBrightness)
			fprintf(stderr, "sweet-displayd: DisplayServices says the main display %s change brightness\n",
			    DisplayServicesCanChangeBrightness(CGMainDisplayID()) ? "can" : "can NOT");
		if (DisplayServicesCanChangeBrightness && !once) {
			pthread_t kick;
			if (pthread_create(&kick, NULL, corebrightness_kick, NULL) == 0)
				pthread_detach(kick);
		}
#else
		void *bbs = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW);
		BKSDisplayBrightnessGetCurrent = bbs ? (float (*)(void))dlsym(bbs, "BKSDisplayBrightnessGetCurrent") : NULL;
#endif
		dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW);
		Class cls = NSClassFromString(@"CBBlueLightClient");
		blueLight = cls ? [cls new] : nil;
		fprintf(stderr, "sweet-displayd: brightness %s, Night Shift %s\n",
		    BKSDisplayBrightnessGetCurrent ? (TARGET_OS_OSX ? "DisplayServicesGetBrightness" : "BKSDisplayBrightnessGetCurrent") : "UNAVAILABLE",
		    blueLight ? "CBBlueLightClient" : "UNAVAILABLE");

		if (once) {
			bool active = false;
			float strength = 0;
			bool ok = night_shift(&active, &strength);
			printf("brightness %.3f; Night Shift %s, on %d, strength %.3f; status bytes:",
			    BKSDisplayBrightnessGetCurrent ? BKSDisplayBrightnessGetCurrent() : -1.0f,
			    ok ? "answers" : "does not answer", active, strength);
			for (int i = 0; i < 40; i++)
				printf("%s%02x", i % 4 ? "" : " ", last_status[i]);
			printf("\n");
			return 0;
		}

		pmem = open("/dev/pmem", O_RDWR);
		if (pmem < 0) {
			fprintf(stderr, "sweet-displayd: /dev/pmem: %s (kernel 0094+, boot-arg sweetpmem=1, root)\n", strerror(errno));
			return 1;
		}
		double last_r = -1, last_g = -1, last_b = -1;
		int last_panel = -1;
		for (;;) {
			@autoreleasepool {
				float level = BKSDisplayBrightnessGetCurrent ? BKSDisplayBrightnessGetCurrent() : 1.0f;
				if (!(level >= 0 && level <= 1))
					level = 1;
				bool active = false;
				float strength = 0;
				night_shift(&active, &strength);

				/*
				 * The slider sets the panel's own brightness (DCS 0x51): bottom 1, top 1023 (user's choice), squared
				 * in between as the slider is perceptual (half way = 256). Scaling pixel values instead crushed colours
				 * (user: red black at 10%), so the colour stage only does Night Shift now.
				 */
				int panel = 1 + (int)lround(1022.0 * (double)level * (double)level);
				if (panel != last_panel && panel_brightness((unsigned)panel)) {
					if (verbose)
						fprintf(stderr, "sweet-displayd: brightness %.3f -> panel %d\n", level, panel);
					last_panel = panel;
				}
				double k = 1.0;
				/* Night Shift at full strength: about 2700 K from 6500 K (green 0.70, blue 0.40) */
				/* a strength of 0 while on: CoreBrightness had none to give (no display module): a middle one */
				if (active && strength < 0.01)
					strength = 0.5f;
				double s = active ? fmin(fmax(strength, 0.0), 1.0) : 0.0;
				double r = k, g = k * (1.0 - 0.30 * s), b = k * (1.0 - 0.60 * s);
				if (fabs(r - last_r) > 0.002 || fabs(g - last_g) > 0.002 || fabs(b - last_b) > 0.002) {
					if (apply(r, g, b)) {
						last_r = r, last_g = g, last_b = b;
						if (verbose)
							fprintf(stderr, "sweet-displayd: brightness %.3f, Night Shift %s %.2f -> %.3f %.3f %.3f\n",
							    level, active ? "on" : "off", strength, r, g, b);
					}
				}
			}
			usleep(100000);
		}
	}
}
