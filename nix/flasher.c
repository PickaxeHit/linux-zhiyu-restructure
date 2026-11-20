/* zhiyu-install: write the boot images of a NixOS toplevel into their slot.
 *
 *   zhiyu-install [--dry-run] [--force] <toplevel>
 *
 * Called by NixOS as system.build.installBootLoader (boot.loader.external),
 * i.e. with the output path of the system to install.  The images live in
 * <toplevel>/etc/zhiyu/boot-images and are the ones that generation was built
 * with, so rolling back the generation also rolls back what is flashed.
 *
 * Only the slot that is currently running is written; the other one may hold
 * Android and is never touched.  A partition whose content already matches is
 * left alone, so ordinary system upgrades do not write to the flash at all.
 * Before any write the target is pinned in zhiyu-pending. After all four
 * partitions have been checked, zhiyu-boot is atomically updated. The boot
 * selector only accepts a generation matching both artifact IDs.
 *
 * --force only disables the "content is already correct" shortcut; it never
 * skips the board, partition or slot checks.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <linux/fs.h>
#include <openssl/evp.h>

#define CHUNK (1024 * 1024)
#define LOCK_PATH "/run/lock/zhiyu-install.lock"
#define PROFILE_DIR "/nix/var/nix/profiles"
#define BOOT_PROFILE PROFILE_DIR "/zhiyu-boot"
#define PENDING_PROFILE PROFILE_DIR "/zhiyu-pending"

static const char *const parts[] = { "boot", "vendor_boot", "init_boot", "vbmeta" };
#define NPARTS (sizeof(parts) / sizeof(parts[0]))

static int dry_run;
static int force;

struct part {
	char name[64];
	char devpath[128];
	char image[4096];
	char sha[65];
	off_t image_size;
	off_t part_size;
	int img_fd;
	int dev_fd;
	dev_t dev_id;
	int needs_write;
};

static void die(const char *msg)
{
	fprintf(stderr, "zhiyu-install: %s\n", msg);
	exit(1);
}

static void die_errno(const char *what, const char *path)
{
	fprintf(stderr, "zhiyu-install: %s %s: %s\n", what, path, strerror(errno));
	exit(1);
}

/* Format into a fixed buffer, refusing to truncate.  Using vsnprintf here
 * keeps the truncation check in one place (and the compiler cannot warn about
 * every call site). */
static void fmt(char *dst, size_t dstlen, const char *format, ...)
{
	va_list ap;
	int n;

	va_start(ap, format);
	n = vsnprintf(dst, dstlen, format, ap);
	va_end(ap);
	if (n < 0 || (size_t)n >= dstlen)
		die("path too long");
}

/* ---- SHA-256 ---------------------------------------------------------- */

static int sha256_fd(int fd, off_t len, unsigned char out[32])
{
	unsigned char *buf = malloc(CHUNK);
	EVP_MD_CTX *ctx = EVP_MD_CTX_new();
	off_t done = 0;
	int rc = -1;
	unsigned int outlen = 32;

	if (!buf || !ctx)
		goto free;
	if (EVP_DigestInit_ex(ctx, EVP_sha256(), NULL) != 1)
		goto free;
	while (done < len) {
		size_t want = (size_t)((len - done) < CHUNK ? (len - done) : CHUNK);
		ssize_t n = pread(fd, buf, want, done);

		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0)
			goto free;
		if (EVP_DigestUpdate(ctx, buf, (size_t)n) != 1)
			goto free;
		done += n;
	}
	if (EVP_DigestFinal_ex(ctx, out, &outlen) != 1)
		goto free;
	rc = 0;
free:
	EVP_MD_CTX_free(ctx);
	free(buf);
	return rc;
}

static void to_hex(const unsigned char *in, char out[65])
{
	for (int i = 0; i < 32; i++)
		sprintf(out + 2 * i, "%02x", in[i]);
}

/* ---- strict manifest parsing ----------------------------------------- */

/* Returns 0 and writes the value, or -1 when the name is absent/duplicated,
 * -2 when the file is malformed. */
static int lookup(const char *dir, const char *file, const char *name, char *out, size_t outlen)
{
	char path[4096], line[8192];
	FILE *f;
	int found = 0;

	fmt(path, sizeof(path), "%s/%s", dir, file);
	f = fopen(path, "r");
	if (!f)
		die_errno("cannot open", path);
	while (fgets(line, sizeof(line), f)) {
		char *tok, *save = NULL, *nm;

		tok = strtok_r(line, " \t\n", &save);
		nm = strtok_r(NULL, " \t\n", &save);
		if (!tok || !nm || strtok_r(NULL, " \t\n", &save)) {
			fclose(f);
			return -2;
		}
		if (strcmp(nm, name) != 0)
			continue;
		if (found++) {
			fprintf(stderr, "zhiyu-install: %s/%s lists %s twice\n", dir, file, name);
			fclose(f);
			return -2;
		}
		if (strlen(tok) >= outlen) {
			fprintf(stderr, "zhiyu-install: %s/%s has an overlong value for %s\n", dir, file, name);
			fclose(f);
			return -2;
		}
		strcpy(out, tok);
	}
	if (ferror(f)) { fclose(f); return -2; }
	fclose(f);
	return found ? 0 : -1;
}

static int parse_size(const char *s, off_t *out)
{
	char *end = NULL;
	long long v;

	if (!*s || strspn(s, "0123456789") != strlen(s)) return -1;
	errno = 0;
	v = strtoll(s, &end, 10);
	if (errno || !end || *end != '\0' || v <= 0)
		return -1;
	*out = (off_t)v;
	return (long long)*out == v ? 0 : -1;
}

static int all_hex(const char *s, size_t n)
{
	if (strlen(s) != n)
		return 0;
	for (size_t i = 0; i < n; i++) {
		char c = s[i];

		if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')))
			return 0;
	}
	return 1;
}

/* ---- platform / slot checks ------------------------------------------ */

static int on_zhiyu(void)
{
	const char *path = "/proc/device-tree/lenovo,mainline-compatible";
	char buf[256];
	int fd, n;

	fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return 0;
	n = (int)read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n <= 0 || n == (int)sizeof(buf) - 1 || buf[n-1] != '\0')
		return 0;
	/* The property is a NUL-separated string list; compare each entry. */
	buf[n] = '\0';
	for (int off = 0; off < n;) {
		size_t len = strlen(buf + off);

		if (strcmp(buf + off, "lenovo,zhiyu") == 0)
			return 1;
		off += (int)len + 1;
	}
	return 0;
}

/* Trim leading/trailing whitespace in place. */
static char *trim(char *s)
{
	size_t n;

	while (*s == ' ' || *s == '\t' || *s == '\r' || *s == '\n')
		s++;
	n = strlen(s);
	while (n && (s[n - 1] == ' ' || s[n - 1] == '\t' || s[n - 1] == '\r' || s[n - 1] == '\n'))
		s[--n] = '\0';
	return s;
}

/* One bootconfig line: androidboot.slot_suffix = "_a" (whitespace optional). */
static int parse_bootconfig_line(char *line, char *slot, int *seen)
{
	static const char key[] = "androidboot.slot_suffix";
	char *p, *val;
	size_t len;

	p = trim(line);
	if (*p == '\0' || *p == '#')
		return 0;
	if (strncmp(p, key, sizeof(key) - 1) != 0)
		return 0;
	p = trim(p + sizeof(key) - 1);
	if (*p != '=')
		return -1;
	p = trim(p + 1);

	/* Exactly one quoted two-character value. */
	len = strlen(p);
	if (len < 4 || p[0] != '"' || p[len - 1] != '"')
		return -1;
	p[len - 1] = '\0';
	val = p + 1;
	if (strcmp(val, "_a") != 0 && strcmp(val, "_b") != 0)
		return -1;
	if (++(*seen) > 1)
		return -1;
	strcpy(slot, val);
	return 0;
}

/* A single cmdline token, exactly "androidboot.slot_suffix=_a|_b". */
static int parse_cmdline_token(const char *tok, char *slot, int *seen)
{
	static const char key[] = "androidboot.slot_suffix=";

	if (strncmp(tok, key, sizeof(key) - 1) != 0)
		return 0;
	tok += sizeof(key) - 1;
	if (strcmp(tok, "_a") != 0 && strcmp(tok, "_b") != 0)
		return -1;
	if (++(*seen) > 1)
		return -1;
	strcpy(slot, tok);
	return 0;
}

/*
 * The slot decides which partitions are written, so it is parsed strictly:
 * either source may supply it, both must agree, and a malformed or duplicate
 * value is fatal (never "fall back to _a").
 */
static char *current_slot(void)
{
	char slot_bc[3] = { 0 }, slot_cl[3] = { 0 };
	int seen_bc = 0, seen_cl = 0;
	char buf[16384], *line, *save;
	ssize_t n;
	FILE *f;
	int fd;

	f = fopen("/proc/bootconfig", "r");
	if (f) {
		while (fgets(buf, sizeof(buf), f)) {
			if (parse_bootconfig_line(buf, slot_bc, &seen_bc) < 0) {
				fclose(f);
				die("malformed androidboot.slot_suffix in /proc/bootconfig");
			}
		}
		if (ferror(f)) die("cannot read /proc/bootconfig");
		fclose(f);
	} else if (errno != ENOENT) {
		die_errno("cannot open", "/proc/bootconfig");
	}

	fd = open("/proc/cmdline", O_RDONLY | O_CLOEXEC);
	if (fd >= 0) {
		n = read(fd, buf, sizeof(buf) - 1);
		close(fd);
		if (n <= 0 || n == (ssize_t)sizeof(buf)-1) die("cannot read complete /proc/cmdline");
		if (n > 0) {
			buf[n] = '\0';
			for (line = strtok_r(buf, " \t\n", &save); line; line = strtok_r(NULL, " \t\n", &save)) {
				if (parse_cmdline_token(line, slot_cl, &seen_cl) < 0)
					die("malformed androidboot.slot_suffix in /proc/cmdline");
			}
		}
	} else {
		die_errno("cannot open", "/proc/cmdline");
	}

	if (seen_bc && seen_cl && strcmp(slot_bc, slot_cl) != 0)
		die("the slot in /proc/bootconfig and /proc/cmdline disagree");
	if (!seen_bc && !seen_cl)
		die("cannot determine the current slot");

	return strdup(seen_bc ? slot_bc : slot_cl);
}

/* Recheck GPT identity on the opened FD, not just its udev link. */
static void check_partname(dev_t dev, const char *expected)
{
	char path[128], line[512];
	FILE *f;
	int found = 0;
	fmt(path, sizeof(path), "/sys/dev/block/%u:%u/uevent", major(dev), minor(dev));
	f = fopen(path, "r");
	if (!f) die_errno("cannot read partition identity", path);
	while (fgets(line, sizeof(line), f)) {
		if (strncmp(line, "PARTNAME=", 9)) continue;
		if (++found != 1 || strcmp(trim(line + 9), expected))
			die("opened block device has the wrong GPT partition name");
	}
	if (ferror(f) || found != 1) die("GPT partition identity unavailable");
	fclose(f);
}

static void sync_profiles(void)
{
	int fd = open(PROFILE_DIR, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
	if (fd < 0) die_errno("cannot open profile directory", PROFILE_DIR);
	if (fsync(fd) < 0) die_errno("cannot sync profile directory", PROFILE_DIR);
	if (close(fd) < 0) die_errno("cannot close profile directory", PROFILE_DIR);
}

/* Direct symlinks under profiles are GC roots. Keep the target pinned before
 * touching the partitions; leave it pinned if an update is interrupted. */
static void set_profile(const char *profile, const char *target)
{
	char tmp[PATH_MAX];
	fmt(tmp, sizeof(tmp), "%s.tmp.%d", profile, (int)getpid());
	if (unlink(tmp) < 0 && errno != ENOENT) die_errno("cannot remove stale link", tmp);
	if (symlink(target, tmp) < 0) die_errno("cannot create profile", tmp);
	if (rename(tmp, profile) < 0) die_errno("cannot commit profile", profile);
	sync_profiles();
}

static void read_boot_ids(const char *path, char out[130])
{
	char a[65], b[65], extra;
	FILE *f = fopen(path, "r");
	if (!f) die_errno("cannot read boot IDs", path);
	if (fscanf(f, "%64s %64s %c", a, b, &extra) != 2 || ferror(f) ||
	    !all_hex(a,64) || !all_hex(b,64)) die("invalid boot ID pair");
	fclose(f);
	fmt(out,130,"%s %s",a,b);
}

/* ---- main -------------------------------------------------------------*/

int main(int argc, char **argv)
{
	const char *system = NULL;
	char images[4096], slot[3], sums[65], sizesz[32], resolved[PATH_MAX];
	struct part p[NPARTS];
	int lockfd, changed = 0;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--dry-run") || !strcmp(argv[i], "-n"))
			dry_run = 1;
		else if (!strcmp(argv[i], "--force") || !strcmp(argv[i], "-f"))
			force = 1;
		else if (!system)
			system = argv[i];
		else
			die("too many arguments");
	}
	if (!system)
		die("usage: zhiyu-install [--dry-run] [--force] <toplevel>");
	if (geteuid() != 0) die("must run as root");

	/* Serialise with any other flash operation (nixos-rebuild vs. hand run). */
	lockfd = open(LOCK_PATH, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
	if (lockfd < 0)
		die_errno("cannot open flash lock", LOCK_PATH);
	if (flock(lockfd, LOCK_EX | LOCK_NB) < 0)
		die("another zhiyu-install is already running");

	if (!on_zhiyu())
		die("not running on a Lenovo TB378FC");

	/* Freeze the generation before resolving any of its files. */
	if (!realpath(system, resolved)) die_errno("cannot resolve", system);
	if (strncmp(resolved, "/nix/store/", 11) || strchr(resolved+11, '/') ||
	    !strstr(resolved+11, "-nixos-system-"))
		die("target must be a NixOS system in /nix/store");
	system = resolved;
	fmt(images, sizeof(images), "%s/etc/zhiyu/boot-images", system);
	if (access(images, R_OK) < 0)
		die_errno("no boot images in", images);
	{
		char path[PATH_MAX], expected[130], actual[130];
		fmt(path,sizeof(path),"%s/etc/zhiyu/boot-id",system);
		read_boot_ids(path,expected);
		fmt(path,sizeof(path),"%s/BOOT-IDS",images);
		read_boot_ids(path,actual);
		if (strcmp(expected,actual)) die("generation and image bundle IDs disagree");
		fmt(path,sizeof(path),"%s/init",system);
		if (access(path,X_OK)<0) die_errno("target init is not executable",path);
	}

	{
		char *s = current_slot();

		strcpy(slot, s);
		free(s);
	}

	/* ---- validate everything and keep the descriptors open ---------- */
	for (size_t i = 0; i < NPARTS; i++) {
		struct part *it = &p[i];
		unsigned char digest[32];
		char hash[65];
		struct stat st;
		int rc;

		memset(it, 0, sizeof(*it));
		it->img_fd = it->dev_fd = -1;
		fmt(it->name, sizeof(it->name), "%s.img", parts[i]);
		fmt(it->image, sizeof(it->image), "%s/%s", images, it->name);
		fmt(it->devpath, sizeof(it->devpath), "/dev/disk/by-partlabel/%s%s", parts[i], slot);

		rc = lookup(images, "SHA256SUMS", it->name, sums, sizeof(sums));
		if (rc != 0)
			die("missing, duplicated or malformed SHA256SUMS entry");
		if (!all_hex(sums, 64))
			die("checksum is not a 64-character lowercase hex digest");
		strcpy(it->sha, sums);

		if (lookup(images, "SIZES", it->name, sizesz, sizeof(sizesz)) != 0)
			die("missing, duplicated or malformed SIZES entry");
		if (parse_size(sizesz, &it->image_size) < 0)
			die("SIZES entry is not a positive decimal size");

		it->img_fd = open(it->image, O_RDONLY | O_CLOEXEC);
		if (it->img_fd < 0)
			die_errno("cannot open image", it->image);
		if (fstat(it->img_fd, &st) < 0)
			die_errno("cannot stat image", it->image);
		if (!S_ISREG(st.st_mode))
			die("image is not a regular file");
		if (st.st_size != it->image_size) {
			fprintf(stderr, "zhiyu-install: %s is %lld bytes but SIZES says %lld\n",
				it->name, (long long)st.st_size, (long long)it->image_size);
			return 1;
		}
		if (sha256_fd(it->img_fd, it->image_size, digest) < 0)
			die_errno("cannot hash", it->image);
		to_hex(digest, hash);
		if (strcmp(hash, it->sha) != 0) {
			fprintf(stderr, "zhiyu-install: %s does not match its checksum\n", it->name);
			return 1;
		}

		it->dev_fd = open(it->devpath, (dry_run ? O_RDONLY : O_RDWR) | O_CLOEXEC);
		if (it->dev_fd < 0)
			die_errno("cannot open partition", it->devpath);
		if (fstat(it->dev_fd, &st) < 0)
			die_errno("cannot stat partition", it->devpath);
		if (!S_ISBLK(st.st_mode))
			die("partition is not a block device");
		it->dev_id = st.st_rdev;
		{
			char label[64];
			fmt(label,sizeof(label),"%s%s",parts[i],slot);
			check_partname(it->dev_id,label);
			for (size_t j=0;j<i;j++)
				if (p[j].dev_id==it->dev_id) die("two partitions resolve to the same device");
		}
		{
			unsigned long long sz;

			if (ioctl(it->dev_fd, BLKGETSIZE64, &sz) < 0)
				die_errno("cannot query partition size", it->devpath);
			it->part_size = (off_t)sz;
		}
		if (it->image_size > it->part_size)
			die("image does not fit its partition");
		if (strcmp(parts[i], "vbmeta") != 0 && it->image_size != it->part_size) {
			fprintf(stderr, "zhiyu-install: %s is %lld bytes, partition is %lld\n",
				it->name, (long long)it->image_size, (long long)it->part_size);
			return 1;
		}
	}

	printf("zhiyu-install: %zu image(s) for slot %s from %s\n", NPARTS, slot, system);

	/* Read all existing partition hashes before the first write. A read
	 * failure is not a reason to overwrite a potentially failing device. */
	for (size_t i=0;i<NPARTS;i++) {
		unsigned char digest[32];
		char hash[65];
		if (sha256_fd(p[i].dev_fd,p[i].image_size,digest)<0)
			die_errno("cannot read partition before flash",p[i].devpath);
		to_hex(digest,hash);
		p[i].needs_write=force || strcmp(hash,p[i].sha)!=0;
	}
	if (!dry_run) set_profile(PENDING_PROFILE, system);

	/* ---- write what differs ---------------------------------------- */
	for (size_t i = 0; i < NPARTS; i++) {
		struct part *it = &p[i];
		unsigned char digest[32];
		char hash[65];
		off_t done = 0;
		unsigned char *buf;

		if (!it->needs_write) {
			printf("zhiyu-install: %s unchanged, skipping\n", parts[i]);
			continue;
		}
		changed++;
		if (dry_run) {
			printf("zhiyu-install: would write %s (%lld bytes) to %s\n",
				it->name, (long long)it->image_size, it->devpath);
			continue;
		}

		printf("zhiyu-install: writing %s (%lld bytes) to %s\n",
			it->name, (long long)it->image_size, it->devpath);
		buf = malloc(CHUNK);
		if (!buf)
			die("out of memory");
		while (done < it->image_size) {
			size_t want = (size_t)((it->image_size - done) < CHUNK ? (it->image_size - done) : CHUNK);
			ssize_t n = pread(it->img_fd, buf, want, done);
			ssize_t w = 0;

			if (n < 0 && errno == EINTR) continue;
			if (n <= 0) {
				free(buf);
				die_errno("cannot read image", it->image);
			}
			while (w < n) {
				ssize_t k = pwrite(it->dev_fd, buf + w, (size_t)(n - w), done + w);

				if (k < 0 && errno == EINTR) continue;
				if (k <= 0) {
					free(buf);
					die_errno("write failed", it->devpath);
				}
				w += k;
			}
			done += n;
		}
		free(buf);
		if (fsync(it->dev_fd) < 0)
			die_errno("fsync failed", it->devpath);
		if (ioctl(it->dev_fd, BLKFLSBUF) < 0 && errno != EINVAL)
			die_errno("cannot flush", it->devpath);
		if (sha256_fd(it->dev_fd, it->image_size, digest) < 0)
			die_errno("read-back failed", it->devpath);
		to_hex(digest, hash);
		if (strcmp(hash, it->sha) != 0) {
			fprintf(stderr, "zhiyu-install: read-back verification failed for %s\n", it->devpath);
			return 1;
		}
	}

	if (dry_run) {
		printf("zhiyu-install: slot %s checked, %d of %zu would be written\n",
			slot, changed, NPARTS);
		return 0;
	}

	/* All four partitions verified. Publish the boot root, then remove the
	 * pending root. An interrupted flash is NOT an atomic slot update. */
	set_profile(BOOT_PROFILE, system);
	if (unlink(PENDING_PROFILE) < 0 && errno != ENOENT)
		die_errno("cannot remove pending profile", PENDING_PROFILE);
	sync_profiles();

	printf("zhiyu-install: slot %s complete (%d written)\n", slot, changed);
	return 0;
}
