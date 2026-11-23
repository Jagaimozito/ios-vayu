/*
 * macos-heicdecode: decode a HEIC (wallpaper) with ImageIO and write it as PNG, to see whether the "squares" in the
 * wallpapers are already in the decoded image (decode/tile stitching) rather than in WindowServer or the display.
 * Also prints the HEIF properties (grid/tile size). 2026-11-22.
 *   heicdecode IN.heic OUT.png [index] [sw]   (sw: ask ImageIO not to use hardware decode/scaling)
 * Build on the Mac: clang -arch arm64 -fobjc-arc -framework Foundation -framework ImageIO -framework CoreGraphics \
 *     -framework UniformTypeIdentifiers -o outputs/heicdecode tools/macos-heicdecode.m
 */
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <dlfcn.h>

int main(int argc, char **argv)
{
	@autoreleasepool {
		if (argc < 3) {
			fprintf(stderr, "usage: heicdecode IN.heic OUT.png [index]\n");
			return 2;
		}
		size_t index = argc > 3 ? (size_t)atoi(argv[3]) : 0;
		NSURL *in = [NSURL fileURLWithPath:@(argv[1])], *out = [NSURL fileURLWithPath:@(argv[2])];
		CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)in, NULL);
		if (!src) {
			fprintf(stderr, "cannot open %s\n", argv[1]);
			return 1;
		}
		printf("type %s, %zu image(s)\n", [(__bridge NSString *)CGImageSourceGetType(src) UTF8String], CGImageSourceGetCount(src));
		NSDictionary *props = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, index, NULL));
		printf("width %s height %s\n", [[props[@"PixelWidth"] description] UTF8String], [[props[@"PixelHeight"] description] UTF8String]);
		for (NSString *k in @[ @"{HEIF}", @"TileWidth", @"TileHeight", @"{TIFF}" ])
			if (props[k])
				printf("%s: %s\n", k.UTF8String, [[props[k] description] UTF8String]);
		CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
		NSMutableDictionary *opt = [NSMutableDictionary dictionary];
		if (argc > 4 && !strcmp(argv[4], "sw")) {
			/* look the keys up at run time so the tool still runs where a key does not exist */
			const char *syms[] = { "kCGImageSourceUseHardwareAcceleration", "kCGImageSourceDecodeRequest", NULL };
			CFStringRef *k = dlsym(RTLD_DEFAULT, syms[0]);
			printf("%s: %s\n", syms[0], k ? "present" : "absent");
			if (k)
				opt[(__bridge NSString *)*k] = @NO;
			else
				opt[@"kCGImageSourceUseHardwareAcceleration"] = @NO;
			opt[(__bridge NSString *)kCGImageSourceShouldCacheImmediately] = @YES;
		}
		CGImageRef img = CGImageSourceCreateImageAtIndex(src, index, (__bridge CFDictionaryRef)opt);
		if (!img) {
			fprintf(stderr, "decode failed\n");
			return 1;
		}
		printf("decoded %zux%zu, %zu bpc, %zu bpp, bytesPerRow %zu, in %.0f ms\n", CGImageGetWidth(img), CGImageGetHeight(img),
		    CGImageGetBitsPerComponent(img), CGImageGetBitsPerPixel(img), CGImageGetBytesPerRow(img),
		    (CFAbsoluteTimeGetCurrent() - t0) * 1000);
		CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)out,
		    (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
		CGImageDestinationAddImage(dst, img, NULL);
		bool ok = CGImageDestinationFinalize(dst);
		printf("wrote %s: %s\n", argv[2], ok ? "ok" : "FAILED");
		CFRelease(dst);
		CGImageRelease(img);
		CFRelease(src);
	}
	return 0;
}
