/*
 * macos-voliconprobe: which volume path makes LaunchServices abort (LinkBinding::resolveBinding) when asked for its
 * icon, as About This Mac's storage list does (-[ASVolumeRecord initWithURL:] -> -[NSWorkspace iconForFile:]).
 * Give one path per run (an abort ends the run). 2026-11-22.
 * Build on the Mac: clang -arch arm64 -fobjc-arc -framework AppKit -o outputs/voliconprobe tools/macos-voliconprobe.m
 */
#import <AppKit/AppKit.h>

static void info(NSString *p)
{
	NSURL *u = [NSURL fileURLWithPath:p];
	NSArray *keys = @[ NSURLIsSymbolicLinkKey, NSURLIsAliasFileKey, NSURLIsDirectoryKey, NSURLIsRegularFileKey,
		NSURLIsPackageKey, NSURLFileResourceTypeKey, NSURLIsMountTriggerKey, NSURLVolumeURLKey, NSURLIsVolumeKey, NSURLVolumeNameKey, NSURLVolumeIdentifierKey,
		NSURLVolumeUUIDStringKey, NSURLVolumeIsRootFileSystemKey, NSURLVolumeIsInternalKey, NSURLVolumeLocalizedFormatDescriptionKey ];
	NSError *e = nil;
	NSDictionary *d = [u resourceValuesForKeys:keys error:&e];
	printf("%s: %s\n", p.UTF8String, d ? d.description.UTF8String : e.description.UTF8String);
}

int main(int argc, char **argv)
{
	@autoreleasepool {
		NSMutableArray *paths = [NSMutableArray array];
		for (int i = 1; i < argc; i++)
			[paths addObject:@(argv[i])];
		if (!paths.count)
			[paths addObjectsFromArray:@[ @"/", @"/System/Volumes/Data", @"/Users/corey", @"/Applications" ]];
		for (NSURL *v in [[NSFileManager defaultManager] mountedVolumeURLsIncludingResourceValuesForKeys:nil options:0])
			printf("mounted volume URL: %s\n", v.path.UTF8String);
		/* One path per process: AppKit cannot be used in a forked child (every path "crashed", on a real Mac too). */
		for (NSString *p in paths) {
			info(p);
			fflush(stdout);
			NSImage *img = [[NSWorkspace sharedWorkspace] iconForFile:p];
			printf("  icon for %s: %s\n", p.UTF8String, img ? "ok" : "nil");
			fflush(stdout);
		}
	}
	return 0;
}
