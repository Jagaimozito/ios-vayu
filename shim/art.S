/*
 * Boot menu pictures (shim/menu.c draw_entry): MENU_ICON x MENU_ICON pixels, 3 bytes R, G, B each,
 * already blended onto the menu background. Made by tools/mkmenuart.py from shim/art/src/NAME.png.
 */
	.section .menuart, "a"
	.balign 16
	.global menu_icon_ios27
menu_icon_ios27:
	.incbin "art/ios27.bin"
	.balign 16
	.global menu_icon_macos27
menu_icon_macos27:
	.incbin "art/macos27.bin"
	.balign 16
	.global menu_icon_android
menu_icon_android:
	.incbin "art/android.bin"
	.balign 16
	/* The boot picture (menu_bootpic): 'SWBP', u16 w, u16 h, RGB. Made on the build machine by tools/mkbootpic.py from
	 * an image file the user gives it; shim/out is git-ignored, so the picture never goes into git. Width 0: none. */
	.global menu_bootpic_data
menu_bootpic_data:
	.incbin "out/bootpic.bin"
	.balign 16
