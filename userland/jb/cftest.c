/*
 * cftest: copy a file the way Foundation's -[NSFileManager copyItemAtPath:toPath:error:] does (copyfile(3) with
 * COPYFILE_ALL | COPYFILE_CLONE | COPYFILE_RECURSIVE ... ) and report each step, to reproduce the PosterBoard /
 * CollectionsPoster snapshot failure "libcopyfile: writing to output file got error: Bad address" (2026-11-23).
 *
 *   cftest SRC DST [all|data|clone|nofollow]   (default: all = COPYFILE_ALL | COPYFILE_CLONE)
 *   cftest -w DIR    write matrix: write() of 1 MB into a new file in DIR with each kind of buffer (malloc, valloc,
 *                    mmap anon, vm_allocate, vm_allocate purgeable) x (cached, F_NOCACHE) x (plain, F_PREALLOCATE
 *                    first, ftruncate first), and pwrite/writev; prints which ones get EFAULT. Also prints the
 *                    statfs f_iosize copyfile sizes its buffer from.
 *
 * Also: COPYFILE_DEBUG=255 in the environment makes libcopyfile log every step to the system log.
 * Before copying it prints stat() of the source (size, blocks, flags), its xattr names, and whether read() of the whole
 * file works; after, whether the copy matches.
 */
#include <copyfile.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <sys/mman.h>
#include <unistd.h>
#include <sys/mount.h>
#include <sys/uio.h>
#include <mach/mach.h>

static void *
getbuf(int kind, size_t len)
{
	void *p = NULL;
	vm_address_t a = 0;
	switch (kind) {
	case 0: p = malloc(len); break;
	case 1: p = valloc(len); break;
	case 2: p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (p == MAP_FAILED) p = NULL; break;
	case 3: if (vm_allocate(mach_task_self(), &a, len, VM_FLAGS_ANYWHERE) == KERN_SUCCESS) p = (void *)a; break;
	case 4: if (vm_allocate(mach_task_self(), &a, len, VM_FLAGS_ANYWHERE | VM_FLAGS_PURGABLE) == KERN_SUCCESS) p = (void *)a; break;
	}
	if (p) memset(p, 0x5a, len);
	return p;
}

static int
writematrix(const char *dir)
{
	static const char *kinds[] = { "malloc", "valloc", "mmap-anon", "vm_allocate", "vm_alloc-purgeable" };
	static const char *preps[] = { "plain", "F_PREALLOCATE", "ftruncate" };
	struct statfs sf;
	if (statfs(dir, &sf) == 0) printf("statfs %s: f_iosize %u f_bsize %u fs %s\n", dir, (unsigned)sf.f_iosize, (unsigned)sf.f_bsize, sf.f_fstypename);
	size_t len = 1 << 20;
	char path[1024];
	snprintf(path, sizeof(path), "%s/cftest-w.tmp", dir);
	for (int k = 0; k < 5; k++)
		for (int nc = 0; nc < 2; nc++)
			for (int pr = 0; pr < 3; pr++)
				for (int how = 0; how < 3; how++) {
					void *b = getbuf(k, len);
					if (!b) { printf("%-18s: no buffer\n", kinds[k]); continue; }
					unlink(path);
					int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
					if (fd < 0) { perror("open"); return 1; }
					if (nc) fcntl(fd, F_NOCACHE, 1);
					if (pr == 1) { fstore_t fs = { F_ALLOCATEALL, F_PEOFPOSMODE, 0, (off_t)len, 0 }; if (fcntl(fd, F_PREALLOCATE, &fs) != 0) printf("  (F_PREALLOCATE failed: %s)\n", strerror(errno)); }
					if (pr == 2) ftruncate(fd, len);
					errno = 0;
					ssize_t n;
					const char *hn = how == 0 ? "write" : how == 1 ? "pwrite" : "writev";
					if (how == 0) n = write(fd, b, len);
					else if (how == 1) n = pwrite(fd, b, len, 0);
					else { struct iovec v = { b, len }; n = writev(fd, &v, 1); }
					int e = errno;
					close(fd);
					printf("%-18s %-8s %-13s %-6s: %zd%s%s\n", kinds[k], nc ? "NOCACHE" : "cached", preps[pr], hn, n,
					    n < 0 ? " " : "", n < 0 ? strerror(e) : "");
					if (k == 0) free(b); else if (k == 1) free(b); else if (k == 2) munmap(b, len); else vm_deallocate(mach_task_self(), (vm_address_t)b, len);
				}
	unlink(path);
	return 0;
}

static int
readall(const char *p, unsigned char **out, size_t *len)
{
	int fd = open(p, O_RDONLY);
	if (fd < 0) return -1;
	struct stat st;
	fstat(fd, &st);
	unsigned char *b = malloc(st.st_size + 1);
	size_t got = 0;
	ssize_t n;
	while ((n = read(fd, b + got, st.st_size - got)) > 0) got += n;
	int e = n < 0 ? errno : 0;
	close(fd);
	*out = b;
	*len = got;
	if (e) { errno = e; return -1; }
	return 0;
}

int
main(int argc, char **argv)
{
	if (argc == 3 && !strcmp(argv[1], "-w"))
		return writematrix(argv[2]);
	if (argc < 3) {
		fprintf(stderr, "usage: cftest SRC DST [all|data|clone|nofollow] | cftest -w DIR\n");
		return 2;
	}
	const char *src = argv[1], *dst = argv[2], *mode = argc > 3 ? argv[3] : "all";
	struct stat st;
	if (stat(src, &st) != 0) { perror("stat src"); return 1; }
	printf("src size %lld blocks %lld blksize %d flags 0x%x mode 0%o uid %d\n", (long long)st.st_size,
	    (long long)st.st_blocks, st.st_blksize, st.st_flags, st.st_mode & 07777, st.st_uid);
	char names[4096];
	ssize_t nl = listxattr(src, names, sizeof(names), XATTR_NOFOLLOW | XATTR_SHOWCOMPRESSION);
	printf("xattrs (%zd bytes):", nl);
	for (ssize_t i = 0; i < nl; i += strlen(names + i) + 1) printf(" %s(%zd)", names + i, getxattr(src, names + i, NULL, 0, 0, XATTR_SHOWCOMPRESSION));
	printf("\n");
	unsigned char *a = NULL, *b = NULL;
	size_t al = 0, bl = 0;
	if (readall(src, &a, &al) != 0) printf("read src: %s (got %zu)\n", strerror(errno), al);
	else printf("read src: ok %zu bytes\n", al);
	int fd = open(src, O_RDONLY);
	void *m = fd >= 0 && st.st_size > 0 ? mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0) : MAP_FAILED;
	if (m == MAP_FAILED) printf("mmap src: %s\n", strerror(errno));
	else {
		volatile unsigned sum = 0;
		for (off_t i = 0; i < st.st_size; i += 4096) sum += ((unsigned char *)m)[i];
		printf("mmap src: ok, touched every page (sum %u)\n", sum);
		munmap(m, st.st_size);
	}
	if (fd >= 0) close(fd);
	copyfile_flags_t f = COPYFILE_ALL | COPYFILE_CLONE;
	if (!strcmp(mode, "data")) f = COPYFILE_DATA;
	else if (!strcmp(mode, "clone")) f = COPYFILE_CLONE_FORCE;
	else if (!strcmp(mode, "nofollow")) f = COPYFILE_ALL | COPYFILE_CLONE | COPYFILE_NOFOLLOW | COPYFILE_EXCL;
	unlink(dst);
	errno = 0;
	int r = copyfile(src, dst, NULL, f);
	printf("copyfile(%s, flags 0x%x) = %d errno %d (%s)\n", mode, f, r, errno, strerror(errno));
	if (r == 0 && readall(dst, &b, &bl) == 0)
		printf("copy %s (%zu vs %zu bytes)\n", (al == bl && !memcmp(a, b, al)) ? "matches" : "DIFFERS", bl, al);
	return r == 0 ? 0 : 1;
}
