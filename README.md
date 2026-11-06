# linux-lunar

A linux-tkg-style kernel builder for Arch Linux and CachyOS, with one purpose:
**fewer memory-allocation stalls while gaming**. It builds a vanilla kernel.org
kernel plus only the lunar patches below; no scheduler patch sets, no other
third-party changes.

## Quick start

```bash
git clone https://github.com/WhitePeace36/linux-lunar.git && cd linux-lunar
$EDITOR customization.cfg        # or ~/.config/linux-lunar.cfg for your overrides
./lunar.sh                       # asks for the kernel version, builds, installs
```

Then reboot into `linux-lunar` (the bootloader entry is created by
mkinitcpio/dracut and your bootloader's hooks like for any Arch kernel).

| Command | Does |
| --- | --- |
| `./lunar.sh` | resolve options, build, install (`makepkg -si`) |
| `./lunar.sh --build-only` | build the packages only |
| `./lunar.sh --prepare` | download, patch and configure into `src/` to inspect |
| `./lunar.sh --list` | current kernel.org releases and which have lunar patches |
| `./lunar.sh --clean` | remove build output and caches |
| `./lunar.sh -- <makepkg options>` | pass options on to makepkg |

For PGP-verified stable tarballs, import the kernel.org keys once:
`gpg --locate-keys torvalds@kernel.org gregkh@kernel.org`
(or set `_pgp_verify="false"`).

## Kernel versions

`_version="7.3"` builds the newest 7.3.x, `"7.3.1"` exactly that release,
`"7.4-rc1"` a release candidate, `""` asks. Patch sets exist for:

| Series | Based on | Status |
| --- | --- | --- |
| 7.3 | 7.3.1 | all five patches booted and load-tested on one machine (see below) |
| 7.4 | 7.4-rc1 | compile-tested only |

A newer point release of the same series (e.g. 7.3.2) usually applies
unchanged. If a patch stops applying, the build stops with an error instead of
continuing without it.

## The lunar patches

Each can be switched off in `customization.cfg`.

| # | Option | Effect |
| --- | --- | --- |
| 0001 | `_patch_filemap_large_folios` | Page-cache folios larger than 32 KiB are allocated without direct reclaim/compaction; kswapd/kcompactd are woken instead and readahead steps down one order at a time. Removes compaction stalls when games stream assets. |
| 0002 | `_patch_boost_min_wmark` | `watermark_boost_factor` no longer raises the **min** watermark, so a fragmentation event cannot push allocations into direct reclaim. |
| 0003 | `_patch_ttm_low_latency` | `ttm.low_latency_alloc`: GPU buffer allocations (amdgpu and other TTM drivers) do one bounded reclaim/compaction round for 2 MiB pages instead of retrying hard. |
| 0004 | `_patch_soft_defrag_mode` | `vm.defrag_mode=2`: kswapd/kcompactd keep whole free 2 MiB blocks like mode 1, but allocations never stall just to avoid a migratetype fallback. |
| 0005 | `_patch_kswapd_hopeless` | A kswapd that gave up ("hopeless") is revived by its own or by global direct-reclaim progress again, not only once free memory is back above the high watermark. |

## Compiled-in defaults

Set in `customization.cfg`, all still changeable at runtime:

| Setting | lunar default | upstream |
| --- | --- | --- |
| `vm.defrag_mode` | 2 | 0 |
| `vm.watermark_scale_factor` | 500 | 10 |
| `vm.watermark_boost_factor` | 600 | 15000 |
| `vm.compaction_proactiveness` | 50 | 20 |
| `vm.swappiness` | 150 | 60 |
| `ttm.low_latency_alloc` | Y | N |
| THP enabled / defrag | always / defer | Kconfig / madvise |

`watermark_boost_factor` is a percentage of the high watermark, so it is kept
small when `watermark_scale_factor` is large (600 ≈ 175 MB on 32 GiB with 500).

`compaction_proactiveness` 50: in `memstress -a 16` runs, 80 halved THP
fallbacks compared with 20 but caused 10-37 ms hitches in streaming reads in
every run (proactive compaction migrates page-cache pages that are being read);
50 kept most of the THP benefit without them.

Build defaults: GCC, `-march=native`, 1000 Hz, `PREEMPT` (full) with
PREEMPT_DYNAMIC, periodic tick, THP `always`, MGLRU on.

## Other options

Base config (Arch, CachyOS, running kernel, file), `localmodconfig` with
modprobed-db, menuconfig/nconfig/xconfig, GCC or LLVM with Thin/Full LTO,
`-march` (native, generic, x86-64-v3, znver4, ...), extra KCFLAGS, timer
frequency, preemption (lazy/full/rt) and PREEMPT_DYNAMIC, tick mode, NR_CPUS,
THP, MGLRU, headers package. See the comments in `customization.cfg`.

## Interrupting and cleaning up

Ctrl+C, closing the terminal, or `kill` stops every build
process (makepkg, make, compilers) and removes `src/`, `pkg/` and partial
downloads (`_cleanup_on_abort`; set it to `"false"` to keep `src/` for
debugging). A failed build is cleaned up the same way. After a successful build
`src/` and `pkg/` are removed too (`_cleanup_after_build`); the packages and the
downloaded kernel tarball are kept. A running `pacman` installation is never
interrupted. `./lunar.sh --clean` removes everything including packages.

## Your own patches

Like linux-tkg: put `*.mypatch` (applied) and `*.myrevert` (reverse-applied
first) into `linux<XY>-lunar-userpatches/` next to `lunar.sh`, e.g.
`linux73-lunar-userpatches/`. Unlike linux-tkg, a patch that fails stops the
build.

## Measuring

`tools/` holds what was used to test the patches. Build `memstress` first:
`gcc -O2 -pthread -o tools/memstress tools/memstress.c`

| Tool | Use |
| --- | --- |
| `memcheck.sh` | show every relevant setting and the live per-zone watermarks / kswapd state |
| `memdiff.sh` | counter deltas (allocstall, compact_stall, THP, PSI, ...) across a gaming session |
| `memstress.c` | provoke stalls: fragmented page cache, pinned unmovable pages, THP heap, streaming reads, optional 2:1-compressible anonymous load (`-a GiB`) for zram |
| `memstall.bt` | bpftrace: every direct reclaim / compaction stall > 1 ms with process and order |
| `fragwatch.sh` | live fragmentation score, free 2 MiB blocks, kswapd state, compaction migrations and THP success per second |

`memstress -q <sec> -B <MiB> -t 0` tests proactive compaction on its own: after
the fragmenting setup it stays idle for `<sec>` seconds, then touches one THP
burst and reports how many 2 MiB chunks got a huge page.

## Test status

- All patches apply and compile with `W=1` on 7.3.1 and 7.4-rc1 (GCC, x86_64,
  THP, MEMCG, MGLRU).
- linux-lunar itself: `./lunar.sh --build-only` ran end to end for 7.3.1
  (reduced x86_64 config, GCC) and produced `linux-lunar` and
  `linux-lunar-headers`. The kernel booted in QEMU with all compiled-in
  defaults active (`vm.defrag_mode=2`, `watermark_scale_factor=500`, boost 600,
  proactiveness 80 at the time, swappiness 150, THP `always`/`defer`, MGLRU on) and
  rejected `defrag_mode=3`. Interrupting with SIGINT (Ctrl+C) and SIGTERM
  during compilation stopped all build processes within about 15 s and left no
  `src/`, `pkg/` or build processes behind.
- The 7.3 patches were booted and load-tested on one gaming PC (32 GiB, zram
  16 GiB, CachyOS) inside a linux-tkg build with Zen's kswapd early-stop patch
  reverted. `memstress -a 16`, 120 s: `allocstall` 819,999 → about 1,500,
  `compact_stall` 11,290 → 0-78, THP fallbacks 99.9 % → 0.06-0.3 %,
  PSI memory 26.6 s → 1-2.4 s.
- Not tested yet: a full Arch/CachyOS config build of linux-lunar on real
  hardware, LLVM/LTO, PREEMPT_RT, NVIDIA DKMS against the headers package.
  One machine is not a benchmark.

## Origin

The patches and scripts were written with an AI assistant (Claude) during an
analysis of the kernel's allocator, kswapd, kcompactd and khugepaged. They are
drafts. Patch 0005 matches an approach already under discussion upstream
("mm/vmscan: clear hopeless kswapd when global direct reclaim makes progress",
linux-mm, July 2026), where it is disputed. Upstream submissions must follow
`Documentation/process/coding-assistants.rst` and carry a human Signed-off-by.

Everything in this repository is licensed under GPL-2.0 (see `LICENSE`), like
the kernel the patches are for. Packaging follows the structure of Arch Linux's
`linux` PKGBUILD.
