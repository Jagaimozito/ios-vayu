/*
 * macos-blittest: Metal copies into a big texture at offsets (as a decoder stitching HEIC grid tiles does), checked
 * pixel by pixel. Every tile gets its own colour; any tile, row or origin the backend gets wrong shows as a mismatch.
 * Cases: texture->texture blit with destinationOrigin, buffer->texture with destinationOrigin and a padded
 * bytesPerRow, an IOSurface-backed destination (decoders output IOSurfaces), and two pixel formats. 2026-11-22.
 * Build on the Mac: clang -arch arm64 -fobjc-arc -framework Foundation -framework Metal -framework IOSurface \
 *     -o outputs/blittest tools/macos-blittest.m
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>

static const int BIG = 1024, TILE = 256, N = BIG / TILE;

static uint32_t colour(int tx, int ty) { return 0xff000000u | (uint32_t)(40 + tx * 60) << 16 | (uint32_t)(40 + ty * 60) << 8 | 0x80u; }

static int check(id<MTLDevice> dev, id<MTLCommandQueue> q, id<MTLTexture> big, const char *what)
{
	id<MTLBuffer> rb = [dev newBufferWithLength:BIG * BIG * 4 options:MTLResourceStorageModeShared];
	id<MTLCommandBuffer> cb = [q commandBuffer];
	id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
	[be copyFromTexture:big sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(BIG, BIG, 1)
	           toBuffer:rb destinationOffset:0 destinationBytesPerRow:BIG * 4 destinationBytesPerImage:BIG * BIG * 4];
	[be endEncoding];
	[cb commit];
	[cb waitUntilCompleted];
	const uint32_t *p = rb.contents;
	int bad = 0, firstx = -1, firsty = -1;
	uint32_t got = 0, want = 0;
	for (int y = 0; y < BIG; y++)
		for (int x = 0; x < BIG; x++) {
			uint32_t w = colour(x / TILE, y / TILE);
			if (p[y * BIG + x] != w) {
				if (!bad++) {
					firstx = x, firsty = y, got = p[y * BIG + x], want = w;
				}
			}
		}
	if (bad)
		printf("%-44s FAIL: %d pixels wrong, first at (%d,%d) got %08x want %08x\n", what, bad, firstx, firsty, got, want);
	else
		printf("%-44s ok\n", what);
	return bad != 0;
}

int main(void)
{
	@autoreleasepool {
		id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
		id<MTLCommandQueue> q = [dev newCommandQueue];
		printf("device: %s\n", dev.name.UTF8String);
		int fails = 0;
		for (int surf = 0; surf < 2; surf++) {
			id<MTLTexture> big;
			MTLTextureDescriptor *bd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
			    width:BIG height:BIG mipmapped:NO];
			bd.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
			if (surf) {
				/* padded rows, as IOSurfaces often have */
				IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)@{
					(id)kIOSurfaceWidth : @(BIG), (id)kIOSurfaceHeight : @(BIG), (id)kIOSurfaceBytesPerElement : @4,
					(id)kIOSurfaceBytesPerRow : @(BIG * 4 + 256), (id)kIOSurfacePixelFormat : @('BGRA') });
				bd.storageMode = MTLStorageModeShared;
				big = [dev newTextureWithDescriptor:bd iosurface:s plane:0];
				CFRelease(s);
			} else {
				bd.storageMode = MTLStorageModePrivate;
				big = [dev newTextureWithDescriptor:bd];
			}
			const char *dname = surf ? "IOSurface dest (row 4352)" : "private dest";
			if (!big) {
				printf("%s: no texture\n", dname);
				fails++;
				continue;
			}
			/* 1: texture -> texture at destinationOrigin */
			id<MTLCommandBuffer> cb = [q commandBuffer];
			id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
			NSMutableArray *keep = [NSMutableArray array];
			for (int ty = 0; ty < N; ty++)
				for (int tx = 0; tx < N; tx++) {
					MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
					    width:TILE height:TILE mipmapped:NO];
					td.storageMode = MTLStorageModeShared;
					id<MTLTexture> t = [dev newTextureWithDescriptor:td];
					uint32_t *px = malloc(TILE * TILE * 4);
					for (int i = 0; i < TILE * TILE; i++)
						px[i] = colour(tx, ty);
					[t replaceRegion:MTLRegionMake2D(0, 0, TILE, TILE) mipmapLevel:0 withBytes:px bytesPerRow:TILE * 4];
					free(px);
					[keep addObject:t];
					[be copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
					         sourceSize:MTLSizeMake(TILE, TILE, 1) toTexture:big destinationSlice:0 destinationLevel:0
					  destinationOrigin:MTLOriginMake(tx * TILE, ty * TILE, 0)];
				}
			[be endEncoding];
			[cb commit];
			[cb waitUntilCompleted];
			char name[96];
			snprintf(name, sizeof(name), "tex->tex tiles, %s", dname);
			fails += check(dev, q, big, name);

			/* 2: one buffer (the whole image, padded rows) -> texture, tile by tile with sourceOffset + destinationOrigin */
			const int pitch = BIG * 4 + 512;
			id<MTLBuffer> sb = [dev newBufferWithLength:pitch * BIG options:MTLResourceStorageModeShared];
			for (int y = 0; y < BIG; y++)
				for (int x = 0; x < BIG; x++)
					((uint32_t *)((char *)sb.contents + y * pitch))[x] = colour(x / TILE, y / TILE);
			cb = [q commandBuffer];
			be = [cb blitCommandEncoder];
			for (int ty = 0; ty < N; ty++)
				for (int tx = 0; tx < N; tx++)
					[be copyFromBuffer:sb sourceOffset:(NSUInteger)(ty * TILE * pitch + tx * TILE * 4) sourceBytesPerRow:pitch
					  sourceBytesPerImage:pitch * TILE sourceSize:MTLSizeMake(TILE, TILE, 1) toTexture:big destinationSlice:0
					    destinationLevel:0 destinationOrigin:MTLOriginMake(tx * TILE, ty * TILE, 0)];
			[be endEncoding];
			[cb commit];
			[cb waitUntilCompleted];
			snprintf(name, sizeof(name), "buf->tex tiles (pitch %d), %s", pitch, dname);
			fails += check(dev, q, big, name);

			/* 3: texture -> texture with a sourceOrigin too (sub-rectangle of a 2x2-tile source) */
			MTLTextureDescriptor *sd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
			    width:BIG height:BIG mipmapped:NO];
			sd.storageMode = MTLStorageModeShared;
			id<MTLTexture> src = [dev newTextureWithDescriptor:sd];
			uint32_t *all = malloc(BIG * BIG * 4);
			for (int y = 0; y < BIG; y++)
				for (int x = 0; x < BIG; x++)
					all[y * BIG + x] = colour(x / TILE, y / TILE);
			[src replaceRegion:MTLRegionMake2D(0, 0, BIG, BIG) mipmapLevel:0 withBytes:all bytesPerRow:BIG * 4];
			free(all);
			cb = [q commandBuffer];
			be = [cb blitCommandEncoder];
			for (int ty = N - 1; ty >= 0; ty--)
				for (int tx = N - 1; tx >= 0; tx--)
					[be copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(tx * TILE, ty * TILE, 0)
					         sourceSize:MTLSizeMake(TILE, TILE, 1) toTexture:big destinationSlice:0 destinationLevel:0
					  destinationOrigin:MTLOriginMake(tx * TILE, ty * TILE, 0)];
			[be endEncoding];
			[cb commit];
			[cb waitUntilCompleted];
			snprintf(name, sizeof(name), "tex->tex with sourceOrigin, %s", dname);
			fails += check(dev, q, big, name);
		}
		printf("%s\n", fails ? "SOME CASES FAILED" : "all cases ok");
		return fails ? 1 : 0;
	}
}
