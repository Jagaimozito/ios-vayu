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
