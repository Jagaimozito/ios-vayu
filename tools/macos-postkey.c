/*
 * macos-postkey: post one key press the way the Accessibility Keyboard does (CGEventPost at the HID tap) and say
 * what TCC answers this process first (2026-11-23). WindowServer refuses Assistive Control's key events ("Sender is
 * prohibited from synthesizing events") although TCC has Accessibility/PostEvent rows for it, with csreq. This tells
 * apart "TCC denies" (preflight false) from "WindowServer refuses a sender TCC allows" (preflight true, still refused).
 *
 *   postkey [KEYCODE]   (default 0 = "a"; run in the user's GUI session: launchctl asuser 501 sudo -u corey postkey)
 *
 * Build on the Mac:  xcrun --sdk macosx clang -arch arm64 -mmacos-version-min=14.0 -O2 -Wall \
 *     -framework ApplicationServices -framework CoreFoundation -o outputs/postkey tools/macos-postkey.c
 */
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int
main(int argc, char **argv)
{
	CGKeyCode key = argc > 1 ? (CGKeyCode)atoi(argv[1]) : 0;
	printf("pid %d uid %d\n", getpid(), getuid());
	printf("AXIsProcessTrusted: %d\n", AXIsProcessTrusted());
	printf("CGPreflightPostEventAccess: %d\n", CGPreflightPostEventAccess());
	printf("CGPreflightListenEventAccess: %d\n", CGPreflightListenEventAccess());
	CGEventRef down = CGEventCreateKeyboardEvent(NULL, key, true);
	CGEventRef up = CGEventCreateKeyboardEvent(NULL, key, false);
	if (down == NULL || up == NULL) {
		printf("CGEventCreateKeyboardEvent failed (no WindowServer connection?)\n");
		return 1;
	}
	sleep(1);
	CGEventPost(kCGHIDEventTap, down);
	usleep(50000);
	CGEventPost(kCGHIDEventTap, up);
	usleep(200000);
	printf("posted key %u down and up at the HID tap\n", key);
	CFRelease(down);
	CFRelease(up);
	return 0;
}
