/*
 * macos-surfscan: describe an IOSurface's planes and scan its whole allocation (macOS 27 on the phone, 2026-11-21).
 *
 *   surfscan ID [RAW_OUT]
 *
 * Prints the surface's properties (IOSurfaceCopyAllValues), plane count and each plane's offset from the base
 * address, then walks the full allocation in 64 KiB blocks and reports which blocks hold anything other than
 * 0x00000000 or opaque black 0xff000000 (BGRA 0,0,0,255). With RAW_OUT the whole allocation is written to a file
 * so it can be searched on the Mac. Used to find whether the GPU's '&BGA' output lands somewhere other than where
 * the CPU/kernel read it.
 *
 * Build on the Mac:  xcrun --sdk macosx clang -arch arm64 -O2 -o outputs/surfscan tools/macos-surfscan.c \
 *                        -framework IOSurface -framework CoreFoundation
 */
#include <IOSurface/IOSurface.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

int
main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: %s ID [RAW_OUT]\n", argv[0]);
		return 2;
	}
	IOSurfaceID sid = (IOSurfaceID)strtoul(argv[1], NULL, 0);
	IOSurfaceRef s = IOSurfaceLookup(sid);
	if (!s) {
		fprintf(stderr, "IOSurfaceLookup(%u) failed\n", sid);
		return 1;
	}
	OSType fmt = IOSurfaceGetPixelFormat(s);
	size_t w = IOSurfaceGetWidth(s), h = IOSurfaceGetHeight(s), bpr = IOSurfaceGetBytesPerRow(s);
	size_t alloc = IOSurfaceGetAllocSize(s), planes = IOSurfaceGetPlaneCount(s);
	printf("surface %u: %zux%zu fmt 0x%08x '%c%c%c%c' bpr %zu alloc %zu (0x%zx) planes %zu, w*h*4 = %zu, extra %zd\n",
	    sid, w, h, (unsigned)fmt, (char)(fmt >> 24), (char)(fmt >> 16), (char)(fmt >> 8), (char)fmt, bpr, alloc, alloc,
	    planes, w * h * 4, (ssize_t)alloc - (ssize_t)(bpr * h));

	CFDictionaryRef all = IOSurfaceCopyAllValues(s);
	if (all) {
		printf("--- properties ---\n");
		fflush(stdout);
		CFShow(all);
		CFRelease(all);
	}

	uint32_t seed = 0;
	kern_return_t kr = IOSurfaceLock(s, kIOSurfaceLockReadOnly, &seed);
	printf("lock: 0x%x\n", kr);
	const uint8_t *base = (const uint8_t *)IOSurfaceGetBaseAddress(s);
	printf("base %p\n", (void *)base);
	for (size_t p = 0; p < planes; p++) {
		const uint8_t *pb = (const uint8_t *)IOSurfaceGetBaseAddressOfPlane(s, p);
		printf("plane %zu: offset 0x%zx %zux%zu bpe %zu bpr %zu elem %zux%zu\n", p, (size_t)(pb - base),
		    IOSurfaceGetWidthOfPlane(s, p), IOSurfaceGetHeightOfPlane(s, p), IOSurfaceGetBytesPerElementOfPlane(s, p),
		    IOSurfaceGetBytesPerRowOfPlane(s, p), IOSurfaceGetElementWidthOfPlane(s, p),
		    IOSurfaceGetElementHeightOfPlane(s, p));
	}
	if (!base) {
		fprintf(stderr, "no base address\n");
		return 1;
	}

	/* 64 KiB blocks: count dwords that are neither 0 nor opaque black */
	const size_t blk = 65536;
	size_t interesting_blocks = 0, first = (size_t)-1, last = 0;
	printf("--- blocks with content (offset: dwords not 0/0xff000000, first such dword) ---\n");
	for (size_t off = 0; off < alloc; off += blk) {
		size_t end = off + blk < alloc ? off + blk : alloc, n = 0;
		uint32_t sample = 0;
		size_t sample_off = 0;
		for (size_t o = off; o + 4 <= end; o += 4) {
			uint32_t v = *(const uint32_t *)(base + o);
			if (v != 0 && v != 0xff000000u) {
				if (n == 0) {
					sample = v;
					sample_off = o;
				}
				n++;
			}
		}
		if (n) {
			interesting_blocks++;
			if (first == (size_t)-1) {
				first = off;
			}
			last = off;
			if (interesting_blocks <= 60) {
				printf("  0x%07zx (row %4zu): %6zu  first 0x%08x at 0x%zx\n", off, bpr ? off / bpr : 0, n, sample,
				    sample_off);
			}
		}
	}
	printf("blocks with content: %zu of %zu", interesting_blocks, (alloc + blk - 1) / blk);
	if (interesting_blocks) {
		printf(", first 0x%zx, last 0x%zx", first, last);
	}
	printf("\n");

	if (argc > 2) {
		FILE *f = fopen(argv[2], "wb");
		if (!f) {
			perror(argv[2]);
		} else {
			fwrite(base, 1, alloc, f);
			fclose(f);
			printf("raw allocation written to %s (%zu bytes)\n", argv[2], alloc);
		}
	}
	if (kr == KERN_SUCCESS) {
		IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, &seed);
	}
	CFRelease(s);
	return 0;
}
