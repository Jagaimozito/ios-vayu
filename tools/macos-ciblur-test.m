/*
 * macos-ciblur-test: Core Image's Gaussian blur on Metal, as IconServices runs it (CIBlurProcessor -> MPSImage),
 * outside iconservicesagent so Metal's MTLReportFailure message reaches stderr. iconservicesagent aborts in
 * MTLReportFailure under MPSImage's blur on the Adreno plugin (2026-11-22); the message names the failing check.
 * Build on the Mac: clang -arch arm64 -fobjc-arc -framework CoreImage -framework Metal -framework Foundation \
 *     -framework CoreGraphics -o outputs/ciblur tools/macos-ciblur-test.m
 */
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>

int main(int argc, char **argv)
{
	@autoreleasepool {
		/* ciblur RADIUS SIZE FORMAT(8|h|f) WORKING(8|h|f) */
		double radius = argc > 1 ? atof(argv[1]) : 8.0;
		int size = argc > 2 ? atoi(argv[2]) : 256;
		char of = argc > 3 ? argv[3][0] : '8', wf = argc > 4 ? argv[4][0] : 'h';
		CIFormat outf = of == 'h' ? kCIFormatRGBAh : of == 'f' ? kCIFormatRGBAf : kCIFormatRGBA8;
		CIFormat workf = wf == '8' ? kCIFormatRGBA8 : wf == 'f' ? kCIFormatRGBAf : kCIFormatRGBAh;
		id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
		printf("device: %s\n", dev ? dev.name.UTF8String : "(none)");
		fflush(stdout);
		NSDictionary *opts = @{ kCIContextWorkingFormat : @(workf) };
		CIContext *ctx = dev ? [CIContext contextWithMTLDevice:dev options:opts] : [CIContext contextWithOptions:opts];
		CIImage *img = [[CIImage imageWithColor:[CIColor colorWithRed:0.2 green:0.5 blue:0.9 alpha:1]]
		    imageByCroppingToRect:CGRectMake(0, 0, 256, 256)];
		CIFilter *blur = [CIFilter filterWithName:@"CIGaussianBlur"];
		[blur setValue:img forKey:kCIInputImageKey];
		[blur setValue:@(radius) forKey:kCIInputRadiusKey];
		printf("rendering blur radius %.1f size %d out %c working %c ...\n", radius, size, of, wf);
		fflush(stdout);
		CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
		CGImageRef cg = [ctx createCGImage:blur.outputImage fromRect:CGRectMake(0, 0, size, size) format:outf colorSpace:cs];
		CGColorSpaceRelease(cs);
		printf("result: %s (%zux%zu)\n", cg ? "ok" : "nil", cg ? CGImageGetWidth(cg) : 0, cg ? CGImageGetHeight(cg) : 0);
		if (cg)
			CGImageRelease(cg);
	}
	return 0;
}
