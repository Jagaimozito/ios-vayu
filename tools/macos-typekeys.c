/*
 * macos-typekeys: type text into whatever has keyboard focus, via WindowServer (macOS 27 on the phone, 2026-11-22).
 *
 *   typekeys TEXT [--return]
 *
 * Posts CGEvent key-down/up pairs for TEXT (digits, lower-case letters, space) and optionally Return, at the HID
 * event tap, so they reach the focused field (e.g. the login window's password field) the same way a keyboard
 * would. For use while there is no working keyboard or touch input. Run inside the console session:
 *   launchctl bsexec $(pgrep -x loginwindow) /var/local/bin/typekeys TEXT --return
 * Prints each step as it goes, so a hang shows where it stopped. Events are created with no event source
 * (see main).
 *
 * Build on the Mac:  xcrun --sdk macosx clang -arch arm64 -O2 -o outputs/typekeys tools/macos-typekeys.c \
 *                        -framework ApplicationServices
 */
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int
keycode(char c)
{
	static const struct { char c; int k; } map[] = {
		{ 'a', 0 }, { 's', 1 }, { 'd', 2 }, { 'f', 3 }, { 'h', 4 }, { 'g', 5 }, { 'z', 6 }, { 'x', 7 }, { 'c', 8 },
		{ 'v', 9 }, { 'b', 11 }, { 'q', 12 }, { 'w', 13 }, { 'e', 14 }, { 'r', 15 }, { 'y', 16 }, { 't', 17 },
		{ '1', 18 }, { '2', 19 }, { '3', 20 }, { '4', 21 }, { '6', 22 }, { '5', 23 }, { '9', 25 }, { '7', 26 },
		{ '8', 28 }, { '0', 29 }, { 'o', 31 }, { 'u', 32 }, { 'i', 34 }, { 'p', 35 }, { 'l', 37 }, { 'j', 38 },
		{ 'k', 40 }, { 'n', 45 }, { 'm', 46 }, { ' ', 49 },
	};
	for (size_t i = 0; i < sizeof(map) / sizeof(map[0]); i++) {
		if (map[i].c == c) {
			return map[i].k;
		}
	}
	return -1;
}

static void
press(CGEventSourceRef src, int k)
{
	CGEventRef down = CGEventCreateKeyboardEvent(src, (CGKeyCode)k, true);
	CGEventRef up = CGEventCreateKeyboardEvent(src, (CGKeyCode)k, false);
	CGEventPost(kCGHIDEventTap, down);
	usleep(40000);
	CGEventPost(kCGHIDEventTap, up);
	usleep(60000);
	CFRelease(down);
	CFRelease(up);
}

int
main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: %s TEXT [--return]\n", argv[0]);
		return 2;
	}
	setvbuf(stdout, NULL, _IONBF, 0);
	/* No event source: with one, SLEventCreate -> CGSEventSourceForID took an error path that called
	 * CGSEventSourceShutdown while holding the same mutex and hung forever (2026-11-22). */
	CGEventSourceRef src = NULL;
	printf("using no event source\n");
	size_t n = 0;
	for (const char *p = argv[1]; *p; p++) {
		int k = keycode(*p);
		if (k < 0) {
			fprintf(stderr, "no key for '%c'\n", *p);
			return 1;
		}
		printf("key %zu...\n", n + 1);
		press(src, k);
		n++;
	}
	if (argc > 2 && strcmp(argv[2], "--return") == 0) {
		press(src, 36);
		n++;
	}
	printf("posted %zu keys\n", n);
	if (src) {
		CFRelease(src);
	}
	return 0;
}
