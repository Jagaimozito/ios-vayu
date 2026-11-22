/*
 * macos-surfdump: write an IOSurface's pixels to a PPM image (macOS 27 on the phone, 2026-11-21).
 *
 *   surfdump ID OUT.ppm [STEP]
 *
 * ID is the surface number SweetFramebuffer logs ("SWEET FB: compose swap N layer 0 surface ID ..."). The surface is
 * read as 4 bytes a pixel, B G R A in memory (BGRA and '&BGA' alike); STEP (default 1) keeps every STEP-th pixel in
 * both directions to make a smaller file. Prints the size, format, row bytes and a few statistics (black, white,
 * mean colour) so the answer is readable without the image.
 *
 * Build on the Mac:  xcrun --sdk macosx clang -arch arm64 -O2 -o outputs/surfdump tools/macos-surfdump.c \
 *                        -framework IOSurface -framework CoreFoundation
 */
#include <IOSurface/IOSurface.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

static float
h2f(uint16_t h)
{
	uint32_t sign = (uint32_t)(h & 0x8000) << 16, exp = (h >> 10) & 0x1f, man = h & 0x3ff, f;
	if (exp == 0) {
		if (man == 0) {
			f = sign;
		} else {
			exp = 127 - 15 + 1;
			while (!(man & 0x400)) {
				man <<= 1;
				exp--;
			}
			f = sign | (exp << 23) | ((man & 0x3ff) << 13);
		}
	} else if (exp == 31) {
		f = sign | 0x7f800000 | (man << 13);
	} else {
		f = sign | ((exp + 127 - 15) << 23) | (man << 13);
	}
	float v;
	memcpy(&v, &f, 4);
	return v;
}

int
main(int argc, char **argv)
{
	if (argc < 3) {
		fprintf(stderr, "usage: %s ID OUT.ppm [STEP]\n", argv[0]);
		return 2;
	}
	IOSurfaceID sid = (IOSurfaceID)strtoul(argv[1], NULL, 0);
	unsigned step = argc > 3 ? (unsigned)strtoul(argv[3], NULL, 0) : 1;
	if (step == 0) {
		step = 1;
	}
	IOSurfaceRef s = IOSurfaceLookup(sid);
	if (!s) {
		fprintf(stderr, "IOSurfaceLookup(%u) failed\n", sid);
		return 1;
	}
	size_t w = IOSurfaceGetWidth(s), h = IOSurfaceGetHeight(s), bpr = IOSurfaceGetBytesPerRow(s);
	size_t bpe = IOSurfaceGetBytesPerElement(s);
	OSType fmt = IOSurfaceGetPixelFormat(s);
	printf("surface %u: %zux%zu bpe %zu bpr %zu fmt 0x%08x '%c%c%c%c' alloc %zu\n", sid, w, h, bpe, bpr, (unsigned)fmt,
	    (char)(fmt >> 24), (char)(fmt >> 16), (char)(fmt >> 8), (char)fmt, IOSurfaceGetAllocSize(s));
	/* 'RGhA' (8 bytes a pixel: R G B A as half floats) is decoded too: CoreAnimation's extended-range layers. */
	const int half = bpe == 8 && fmt == 0x52476841;
	if (bpe != 4 && !half) {
		fprintf(stderr, "not 4 bytes a pixel\n");
		return 1;
	}
	uint32_t seed = 0;
	kern_return_t kr = IOSurfaceLock(s, kIOSurfaceLockReadOnly, &seed);
	if (kr != KERN_SUCCESS) {
		fprintf(stderr, "IOSurfaceLock: 0x%x (reading anyway)\n", kr);
	}
	const uint8_t *base = (const uint8_t *)IOSurfaceGetBaseAddress(s);
	if (!base) {
		fprintf(stderr, "no base address\n");
		return 1;
	}
	FILE *f = fopen(argv[2], "wb");
	if (!f) {
		perror(argv[2]);
		return 1;
	}
	size_t ow = (w + step - 1) / step, oh = (h + step - 1) / step;
	fprintf(f, "P6\n%zu %zu\n255\n", ow, oh);
	uint64_t n = 0, black = 0, white = 0, sr = 0, sg = 0, sb = 0, sa = 0, over = 0;
	float maxv = 0;
	for (size_t y = 0; y < h; y += step) {
		const uint8_t *row = base + y * bpr;
		for (size_t x = 0; x < w; x += step) {
			uint8_t q[4];
			const uint8_t *p = row + 4 * x;
			if (half) {
				const uint16_t *hp = (const uint16_t *)(row + 8 * x);
				float hmax = 0;
				for (int c = 0; c < 4; c++) {
					float v = h2f(hp[c]);
					if (c < 3 && v > hmax) {
						hmax = v;
					}
					q[c] = v <= 0 ? 0 : v >= 1 ? 255 : (uint8_t)(v * 255.0f + 0.5f);
				}
				if (hmax > 1.0f) {
					over++;
				}
				if (hmax > maxv) {
					maxv = hmax;
				}
				uint8_t t = q[0];       /* to B G R A order like the 8-bit formats */
				q[0] = q[2];
				q[2] = t;
				p = q;
			}
			uint8_t rgb[3] = { p[2], p[1], p[0] };
			fwrite(rgb, 1, 3, f);
			n++;
			sr += p[2];
			sg += p[1];
			sb += p[0];
			sa += p[3];
			if (p[0] < 16 && p[1] < 16 && p[2] < 16) {
				black++;
			}
			if (p[0] > 239 && p[1] > 239 && p[2] > 239) {
				white++;
			}
		}
	}
	fclose(f);
	if (kr == KERN_SUCCESS) {
		IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, &seed);
	}
	printf("wrote %s %zux%zu: pixels %llu black %llu white %llu mean R %llu G %llu B %llu A %llu\n", argv[2], ow, oh,
	    (unsigned long long)n, (unsigned long long)black, (unsigned long long)white, (unsigned long long)(sr / n),
	    (unsigned long long)(sg / n), (unsigned long long)(sb / n), (unsigned long long)(sa / n));
	if (half) {
		printf("half floats: brightest component %.3f, pixels above 1.0: %llu\n", maxv, (unsigned long long)over);
	}
	/* rows: mean brightness of every 64th row band, to find the black band without the image */
	if (half) {
		CFRelease(s);
		return 0;
	}
	printf("row bands (y: mean of R+G+B /3):");
	for (size_t y0 = 0; y0 < h; y0 += 64) {
		uint64_t t = 0, c = 0;
		for (size_t y = y0; y < y0 + 64 && y < h; y += 4) {
			const uint8_t *row = base + y * bpr;
			for (size_t x = 0; x < w; x += 8) {
				t += (row[4 * x] + row[4 * x + 1] + row[4 * x + 2]) / 3;
				c++;
			}
		}
		printf(" %zu:%llu", y0, (unsigned long long)(c ? t / c : 0));
	}
	printf("\n");
	CFRelease(s);
	return 0;
}
