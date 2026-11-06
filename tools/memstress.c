// SPDX-License-Identifier: GPL-2.0
/*
 * memstress.c - provoke and measure memory-allocation stalls.
 *
 * Recreates the conditions behind allocstall/compact_stall on a gaming box:
 *   1. fill RAM with small (4 KiB) page-cache folios from a big file
 *   2. punch scattered holes into that cache (free memory becomes fragmented)
 *   3. pin unmovable kernel pages (pipe buffers) into those holes, so the
 *      2 MiB pageblocks get mixed and cannot be compacted back
 *   4. optionally (-a) hold N GiB of anonymous "background app" memory that
 *      only compresses about 2:1, so reclaim has to push it to zram/swap
 *   5. for N seconds, run a "game": one thread allocates/touches/frees a big
 *      THP-eligible heap, one thread streams the file with readahead, and
 *      (with -a) one thread touches random pages of the held memory;
 *      every 2 MiB heap chunk, 1 MiB read and 4 KiB touch is timed
 * and prints latency histograms plus the /proc/vmstat + PSI deltas.
 *
 * Build: gcc -O2 -pthread -o memstress memstress.c
 * Run:   sudo ./memstress -f /path/bigfile [-F fill_GiB] [-p pipes] [-t sec] [-b heap_MiB] [-a anon_GiB]
 *                                        [-q quiet_sec [-B burst_MiB]]
 *
 * -q tests proactive compaction: after the setup the program stays idle for
 * quiet_sec (memory is not under pressure, so kcompactd may compact
 * proactively), printing the fragmentation score every 10 s, then touches one
 * burst_MiB THP-eligible burst (default 4096) and reports how many 2 MiB
 * chunks got a huge page. Then the normal -t load runs (use -t 0 to skip it).
 *        bigfile should be larger than RAM (e.g. 48 GiB on a 32 GiB box), on a
 *        filesystem with large-folio support (ext4, xfs, btrfs):
 *        fallocate -l 48G bigfile   (or dd if=/dev/urandom ... for real data)
 *
 * Root is needed for many large pipes (pipe-user-pages-soft) and a high fd limit.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define MiB (1024UL * 1024)
#define GiB (1024UL * MiB)
#define NBUCKETS 24 /* log2(us): 1us .. ~8s */

struct hist {
	uint64_t b[NBUCKETS];
	uint64_t n, max_us, over1ms, over10ms;
};

static atomic_int stop;
static const char *path;
static size_t heap_bytes = 512 * MiB;
static char *anon;
static size_t anon_bytes;

static uint64_t now_us(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000000ULL + ts.tv_nsec / 1000;
}

static void hist_add(struct hist *h, uint64_t us)
{
	int i = 0;

	while ((1ULL << (i + 1)) <= us && i < NBUCKETS - 1)
		i++;
	h->b[i]++;
	h->n++;
	if (us > h->max_us)
		h->max_us = us;
	if (us >= 1000)
		h->over1ms++;
	if (us >= 10000)
		h->over10ms++;
}

static uint64_t hist_pct(const struct hist *h, double p)
{
	uint64_t want = (uint64_t)(h->n * p), seen = 0;

	for (int i = 0; i < NBUCKETS; i++) {
		seen += h->b[i];
		if (seen > want)
			return 1ULL << (i + 1);
	}
	return h->max_us;
}

static void hist_print(const char *name, const struct hist *h)
{
	printf("\n%s: %llu ops, p50 <%llu us, p99 <%llu us, p99.9 <%llu us, max %llu us, >=1ms %llu, >=10ms %llu\n",
	       name, (unsigned long long)h->n,
	       (unsigned long long)hist_pct(h, 0.50), (unsigned long long)hist_pct(h, 0.99),
	       (unsigned long long)hist_pct(h, 0.999), (unsigned long long)h->max_us,
	       (unsigned long long)h->over1ms, (unsigned long long)h->over10ms);
	for (int i = 0; i < NBUCKETS; i++)
		if (h->b[i])
			printf("  %8llu .. %-8llu us  %llu\n", 1ULL << i, 1ULL << (i + 1),
			       (unsigned long long)h->b[i]);
}

/* ---- /proc snapshots ------------------------------------------------ */

static const char *keys[] = {
	"allocstall_normal", "allocstall_movable", "allocstall_dma32",
	"pgscan_direct", "pgscan_direct_throttle", "pgscan_kswapd",
	"compact_stall", "compact_fail", "compact_success",
	"thp_fault_alloc", "thp_fault_fallback", "workingset_refault_file",
	"pswpin", "pswpout", "pgmigrate_success", "compact_daemon_migrate_scanned",
};
#define NKEYS (sizeof(keys) / sizeof(keys[0]))

struct snap {
	long long v[NKEYS];
	long long psi_some, psi_full;
};

static void take_snap(struct snap *s)
{
	char name[128];
	long long val;
	FILE *f = fopen("/proc/vmstat", "r");

	memset(s, 0, sizeof(*s));
	while (f && fscanf(f, "%127s %lld", name, &val) == 2)
		for (size_t i = 0; i < NKEYS; i++)
			if (!strcmp(name, keys[i]))
				s->v[i] = val;
	if (f)
		fclose(f);
	f = fopen("/proc/pressure/memory", "r");
	if (f) {
		char kind[8];
		double a, b, c;
		long long t;

		while (fscanf(f, "%7s avg10=%lf avg60=%lf avg300=%lf total=%lld",
			      kind, &a, &b, &c, &t) == 5) {
			if (!strcmp(kind, "some"))
				s->psi_some = t;
			else
				s->psi_full = t;
		}
		fclose(f);
	}
}

static long long meminfo(const char *key)
{
	char name[64];
	long long val;
	FILE *f = fopen("/proc/meminfo", "r");

	while (f && fscanf(f, "%63s %lld kB\n", name, &val) == 2)
		if (!strncmp(name, key, strlen(key)) && name[strlen(key)] == ':') {
			fclose(f);
			return val * 1024;
		}
	if (f)
		fclose(f);
	return -1;
}

/*
 * Share of free memory that is not in free blocks of 2 MiB or larger, over
 * all zones: the kernel's fragmentation score for proactive compaction
 * (extfrag_for_order(zone, 9)), here summed instead of size-weighted.
 */
static void frag_score(double *score, double *free_mib, double *blocks_mib)
{
	char line[512];
	FILE *f = fopen("/proc/buddyinfo", "r");
	double fr = 0, suit = 0;

	while (f && fgets(line, sizeof(line), f)) {
		char *p = strstr(line, "zone");
		long c;
		int order = 0, n;

		if (!p)
			continue;
		p += 4;
		while (*p == ' ')
			p++;
		while (*p && *p != ' ')
			p++;		/* skip zone name */
		while (sscanf(p, "%ld%n", &c, &n) == 1) {
			fr += (double)c * (1UL << order);
			if (order >= 9)
				suit += (double)c * (1UL << order);
			order++;
			p += n;
		}
	}
	if (f)
		fclose(f);
	*free_mib = fr * 4096 / MiB;
	*blocks_mib = suit * 4096 / MiB;
	*score = fr ? (fr - suit) * 100 / fr : 0;
}

static void print_frag(const char *when)
{
	double sc, fr, bl;

	frag_score(&sc, &fr, &bl);
	printf("  %-10s free %6.0f MiB, in 2 MiB blocks %6.0f MiB, fragmentation score %5.1f\n",
	       when, fr, bl, sc);
	fflush(stdout);
}

/* ---- setup phases ----------------------------------------------------- */

static void fill_cache(int fd, size_t bytes)
{
	char *buf = malloc(MiB);
	size_t done = 0;

	/* FADV_RANDOM: no readahead -> order-0 page-cache folios */
	posix_fadvise(fd, 0, 0, POSIX_FADV_RANDOM);
	while (done < bytes) {
		ssize_t r = pread(fd, buf, MiB, done);

		if (r <= 0)
			break;
		done += r;
	}
	posix_fadvise(fd, 0, 0, POSIX_FADV_NORMAL);
	free(buf);
	printf("  filled %.1f GiB of page cache\n", (double)done / GiB);
}

static void punch_holes(int fd, size_t bytes)
{
	/* drop 16 KiB out of every 64 KiB: 25% freed, scattered everywhere */
	for (size_t off = 0; off + 64 * 1024 <= bytes; off += 64 * 1024)
		posix_fadvise(fd, off + 24 * 1024, 16 * 1024, POSIX_FADV_DONTNEED);
	printf("  punched holes, MemFree now %.1f GiB\n", (double)meminfo("MemFree") / GiB);
}

static int pin_unmovable(int npipes)
{
	static char chunk[64 * 1024];
	int made = 0;

	memset(chunk, 0x5a, sizeof(chunk));
	for (int i = 0; i < npipes; i++) {
		int p[2];

		if (pipe2(p, O_NONBLOCK))
			break;
		if (write(p[1], chunk, sizeof(chunk)) <= 0) {
			close(p[0]);
			close(p[1]);
			break;
		}
		made++;	/* fds stay open: 16 pinned unmovable pages per pipe */
	}
	printf("  pinned %d pipes = %.0f MiB of unmovable pages\n", made, made * 64.0 / 1024);
	return made;
}

static uint64_t xorshift(uint64_t *x)
{
	*x ^= *x << 13;
	*x ^= *x >> 7;
	*x ^= *x << 17;
	return *x;
}

static void hold_anon(size_t bytes)
{
	uint64_t seed = 0x9e3779b97f4a7c15ULL;

	anon = mmap(NULL, bytes, PROT_READ | PROT_WRITE,
		    MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (anon == MAP_FAILED) {
		perror("mmap anon");
		exit(1);
	}
	/* first half of each page random, second half zero: ~2:1 in zram */
	for (size_t off = 0; off < bytes; off += 4096) {
		uint64_t *w = (uint64_t *)(anon + off);

		for (int i = 0; i < 256; i++)
			w[i] = xorshift(&seed);
	}
	anon_bytes = bytes;
	printf("  holding %.1f GiB of anonymous memory (~2:1 compressible)\n",
	       (double)bytes / GiB);
}

/* ---- the "game" ----------------------------------------------------- */

static void *anon_thread(void *arg)
{
	struct hist *h = arg;
	uint64_t seed = 0xdeadbeefcafef00dULL;
	size_t pages = anon_bytes / 4096;
	volatile char sink;

	while (!atomic_load(&stop)) {
		size_t pg = xorshift(&seed) % pages;
		uint64_t t0 = now_us();

		sink = anon[pg * 4096 + 8];
		hist_add(h, now_us() - t0);
		(void)sink;
		usleep(50);	/* ~10-20k touches/s, like background apps */
	}
	return NULL;
}

static void *heap_thread(void *arg)
{
	struct hist *h = arg;

	while (!atomic_load(&stop)) {
		char *p = mmap(NULL, heap_bytes, PROT_READ | PROT_WRITE,
			       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);

		if (p == MAP_FAILED)
			break;
		for (size_t off = 0; off < heap_bytes && !atomic_load(&stop); off += 2 * MiB) {
			uint64_t t0 = now_us();

			for (size_t i = 0; i < 2 * MiB; i += 4096)
				p[off + i] = 1;
			hist_add(h, now_us() - t0);
		}
		munmap(p, heap_bytes);
	}
	return NULL;
}

static void *stream_thread(void *arg)
{
	struct hist *h = arg;
	int fd = open(path, O_RDONLY);
	char *buf = malloc(MiB);
	off_t off = 0;

	posix_fadvise(fd, 0, 0, POSIX_FADV_SEQUENTIAL);
	while (!atomic_load(&stop)) {
		uint64_t t0 = now_us();
		ssize_t r = pread(fd, buf, MiB, off);

		hist_add(h, now_us() - t0);
		off = (r <= 0) ? 0 : off + r;
	}
	free(buf);
	close(fd);
	return NULL;
}

static void quiet_and_burst(int quiet, size_t burst)
{
	struct snap a, b;
	struct hist h = { 0 };
	char *p;

	printf("quiet phase: %d s without load (proactive compaction may run)\n", quiet);
	print_frag("start");
	for (int t = 10; t <= quiet; t += 10) {
		char when[16];

		sleep(10);
		snprintf(when, sizeof(when), "%d s", t);
		print_frag(when);
	}
	if (quiet % 10)
		sleep(quiet % 10);

	take_snap(&a);
	p = mmap(NULL, burst, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (p == MAP_FAILED) {
		perror("mmap burst");
		exit(1);
	}
	for (size_t off = 0; off < burst; off += 2 * MiB) {
		uint64_t t0 = now_us();

		for (size_t i = 0; i < 2 * MiB; i += 4096)
			p[off + i] = 1;
		hist_add(&h, now_us() - t0);
	}
	take_snap(&b);
	munmap(p, burst);

	long long got = b.v[9] - a.v[9], fb = b.v[10] - a.v[10];

	printf("\nburst after quiet phase: %zu MiB = %zu chunks of 2 MiB\n", burst / MiB, burst / (2 * MiB));
	printf("  huge pages %lld, fallbacks %lld (%.1f %% got a huge page)\n",
	       got, fb, got + fb ? got * 100.0 / (got + fb) : 0);
	printf("  compact_stall %lld, allocstall %lld\n", b.v[6] - a.v[6],
	       (b.v[0] - a.v[0]) + (b.v[1] - a.v[1]) + (b.v[2] - a.v[2]));
	hist_print("burst: time per 2 MiB first-touch", &h);
	printf("\n");
}

int main(int argc, char **argv)
{
	int npipes = 20000, secs = 120, quiet = 0, opt, fd;
	size_t fill = 0, hold = 0, burst = 4096 * MiB;
	struct hist heap = { 0 }, stream = { 0 }, touch = { 0 };
	struct snap a, b;
	pthread_t th[3];
	struct stat st;

	while ((opt = getopt(argc, argv, "f:F:p:t:b:a:q:B:")) != -1) {
		switch (opt) {
		case 'f': path = optarg; break;
		case 'F': fill = (size_t)(atof(optarg) * GiB); break;
		case 'p': npipes = atoi(optarg); break;
		case 't': secs = atoi(optarg); break;
		case 'b': heap_bytes = (size_t)atol(optarg) * MiB; break;
		case 'a': hold = (size_t)(atof(optarg) * GiB); break;
		case 'q': quiet = atoi(optarg); break;
		case 'B': burst = (size_t)atol(optarg) * MiB; break;
		default: goto usage;
		}
	}
	if (!path)
		goto usage;
	fd = open(path, O_RDONLY);
	if (fd < 0 || fstat(fd, &st)) {
		perror(path);
		return 1;
	}
	if (!fill)
		fill = meminfo("MemTotal");
	if (fill > (size_t)st.st_size)
		fill = st.st_size;

	struct rlimit rl = { npipes * 2 + 64, npipes * 2 + 64 };

	if (setrlimit(RLIMIT_NOFILE, &rl))
		fprintf(stderr, "warning: could not raise fd limit (run as root?): %s\n",
			strerror(errno));

	printf("setup:\n");
	if (hold)
		hold_anon(hold);
	fill_cache(fd, fill);
	punch_holes(fd, fill);
	pin_unmovable(npipes);

	if (quiet > 0)
		quiet_and_burst(quiet, burst);
	if (secs <= 0)
		return 0;

	printf("running game load for %d s (heap %zu MiB bursts + streaming reads)...\n",
	       secs, heap_bytes / MiB);
	take_snap(&a);
	pthread_create(&th[0], NULL, heap_thread, &heap);
	pthread_create(&th[1], NULL, stream_thread, &stream);
	if (hold)
		pthread_create(&th[2], NULL, anon_thread, &touch);
	sleep(secs);
	atomic_store(&stop, 1);
	pthread_join(th[0], NULL);
	pthread_join(th[1], NULL);
	if (hold)
		pthread_join(th[2], NULL);
	take_snap(&b);

	hist_print("heap: time per 2 MiB first-touch (THP fault or 512 small faults)", &heap);
	hist_print("stream: time per 1 MiB read()", &stream);
	if (hold)
		hist_print("apps: time per random 4 KiB touch of held memory (zram swap-in if evicted)", &touch);
	printf("\nvmstat / PSI deltas:\n");
	for (size_t i = 0; i < NKEYS; i++)
		printf("  %-26s %lld\n", keys[i], b.v[i] - a.v[i]);
	printf("  %-26s %lld\n  %-26s %lld\n", "psi_mem_some_us", b.psi_some - a.psi_some,
	       "psi_mem_full_us", b.psi_full - a.psi_full);
	return 0;	/* pipes and cache are released on exit */
usage:
	fprintf(stderr, "usage: %s -f bigfile [-F fill_GiB] [-p pipes] [-t sec] [-b heap_MiB] [-a anon_GiB] [-q quiet_sec [-B burst_MiB]]\n", argv[0]);
	return 2;
}
