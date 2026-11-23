/*
 * macos-extents: where a file's data lies on its disk (F_LOG2PHYS_EXT), one line per contiguous run:
 *   <file offset> <device offset> <bytes>
 * For an offline restore from TWRP of a file on the SWEET root (/dev/disk0 = the "macos" partition): dd the
 * original bytes back at the same device offsets. 2026-11-22.
 * Build on the Mac: clang -arch arm64 -O2 -o outputs/extents tools/macos-extents.c
 */
#include <fcntl.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/stat.h>

int main(int argc, char **argv)
{
	for (int a = 1; a < argc; a++) {
		int fd = open(argv[a], O_RDONLY);
		struct stat st;
		if (fd < 0 || fstat(fd, &st) != 0) {
			fprintf(stderr, "%s: %s\n", argv[a], strerror(errno));
			return 1;
		}
		printf("# %s size %lld ino %llu\n", argv[a], (long long)st.st_size, (unsigned long long)st.st_ino);
		off_t off = 0;
		while (off < st.st_size) {
			struct log2phys l = { 0 };
			l.l2p_contigbytes = st.st_size - off;
			l.l2p_devoffset = off;
			if (fcntl(fd, F_LOG2PHYS_EXT, &l) != 0) {
				fprintf(stderr, "%s: F_LOG2PHYS_EXT at %lld: %s\n", argv[a], (long long)off, strerror(errno));
				return 1;
			}
			if (l.l2p_contigbytes <= 0) {
				fprintf(stderr, "%s: no progress at %lld\n", argv[a], (long long)off);
				return 1;
			}
			printf("%lld %lld %lld\n", (long long)off, (long long)l.l2p_devoffset, (long long)l.l2p_contigbytes);
			off += l.l2p_contigbytes;
		}
		close(fd);
	}
	return 0;
}
