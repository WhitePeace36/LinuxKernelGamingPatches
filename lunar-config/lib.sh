# shellcheck shell=bash
# linux-lunar shared functions.
# Sourced by lunar.sh (resolve options, write .lunar-build.cfg) and by the
# PKGBUILD's prepare() (patch, set defaults, configure).

# ---------------------------------------------------------------- messages --

_l_msg()  { printf '\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
_l_msg2() { printf '  \033[1;34m->\033[0m %s\n' "$*"; }
_l_warn() { printf '\033[1;33m==> WARNING:\033[0m %s\n' "$*" >&2; }
_l_die()  { printf '\033[1;31m==> ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

_l_true() { [[ "${1,,}" == "true" || "${1,,}" == "yes" || "$1" == "1" ]]; }

# ------------------------------------------------------------- the options --

# Every option customization.cfg knows; written to .lunar-build.cfg as resolved.
_LUNAR_OPTIONS=(
	_version _pkgsuffix _localversion _pgp_verify
	_base_config _localmodconfig _modprobeddb_path _menuconfig
	_compiler _lto_mode _march _kcflags _jobs
	_timer_freq _preempt _preempt_dynamic _tickless _nr_cpus
	_thp_enabled _thp_defrag _mglru
	_patch_filemap_large_folios _patch_boost_min_wmark _patch_ttm_low_latency
	_patch_soft_defrag_mode _patch_kswapd_hopeless
	_default_defrag_mode _default_watermark_scale_factor
	_default_watermark_boost_factor _default_compaction_proactiveness
	_default_swappiness _default_ttm_low_latency
	_user_patches _user_patches_confirm _build_headers _noninteractive
	_cleanup_on_abort _cleanup_after_build
)

# Load customization.cfg, then the personal override file.
lunar_load_options() {
	local where="$1"
	# shellcheck disable=SC1091
	source "$where/customization.cfg"
	local user_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/linux-lunar.cfg"
	if [[ -f "$user_cfg" ]]; then
		_l_msg2 "Reading overrides from $user_cfg"
		# shellcheck disable=SC1090
		source "$user_cfg"
	fi
}

_l_in() { local x="$1"; shift; local y; for y; do [[ "$x" == "$y" ]] && return 0; done; return 1; }
_l_int_range() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= $2 && $1 <= $3 )); }

# Check every option; die on the first invalid one.
lunar_validate_options() {
	_l_in "$_compiler" gcc llvm || _l_die "_compiler must be gcc or llvm (is '$_compiler')"
	_l_in "$_lto_mode" none thin full || _l_die "_lto_mode must be none, thin or full"
	if [[ "$_lto_mode" != none && "$_compiler" != llvm ]]; then
		_l_die "_lto_mode=$_lto_mode needs _compiler=llvm"
	fi
	_l_in "$_timer_freq" 100 250 300 1000 || _l_die "_timer_freq must be 100, 250, 300 or 1000"
	_l_in "$_preempt" lazy full rt || _l_die "_preempt must be lazy, full or rt"
	_l_in "$_tickless" periodic idle full || _l_die "_tickless must be periodic, idle or full"
	_l_in "$_menuconfig" none menuconfig nconfig xconfig || _l_die "_menuconfig must be none, menuconfig, nconfig or xconfig"
	_l_in "$_thp_enabled" always madvise never || _l_die "_thp_enabled must be always, madvise or never"
	_l_in "$_thp_defrag" always defer defer+madvise madvise never || _l_die "_thp_defrag must be always, defer, defer+madvise, madvise or never"
	[[ -z "$_nr_cpus" ]] || _l_int_range "$_nr_cpus" 2 8192 || _l_die "_nr_cpus must be a number from 2 to 8192"
	[[ -z "$_jobs" ]] || _l_int_range "$_jobs" 1 4096 || _l_die "_jobs must be a positive number"
	[[ "$_march" =~ ^[A-Za-z0-9_.+-]+$ ]] || _l_die "_march contains invalid characters"
	[[ "$_pkgsuffix" =~ ^[a-z0-9][a-z0-9_.+-]*$ ]] || _l_die "_pkgsuffix must be lower case letters, digits and _.+-"
	[[ -z "$_localversion" || "$_localversion" =~ ^[A-Za-z0-9_.+-]+$ ]] || _l_die "_localversion contains invalid characters"

	if [[ -n "$_default_defrag_mode" ]]; then
		_l_int_range "$_default_defrag_mode" 0 2 || _l_die "_default_defrag_mode must be 0, 1 or 2"
		if [[ "$_default_defrag_mode" == 2 ]] && ! _l_true "$_patch_soft_defrag_mode"; then
			_l_die "_default_defrag_mode=2 needs _patch_soft_defrag_mode=true"
		fi
	fi
	[[ -z "$_default_watermark_scale_factor" ]] || _l_int_range "$_default_watermark_scale_factor" 1 3000 \
		|| _l_die "_default_watermark_scale_factor must be 1..3000"
	[[ -z "$_default_watermark_boost_factor" ]] || _l_int_range "$_default_watermark_boost_factor" 0 1000000 \
		|| _l_die "_default_watermark_boost_factor must be a number >= 0"
	[[ -z "$_default_compaction_proactiveness" ]] || _l_int_range "$_default_compaction_proactiveness" 0 100 \
		|| _l_die "_default_compaction_proactiveness must be 0..100"
	[[ -z "$_default_swappiness" ]] || _l_int_range "$_default_swappiness" 0 200 \
		|| _l_die "_default_swappiness must be 0..200"
	if _l_true "$_default_ttm_low_latency" && ! _l_true "$_patch_ttm_low_latency"; then
		_l_die "_default_ttm_low_latency=true needs _patch_ttm_low_latency=true"
	fi
	return 0
}

# ------------------------------------------------------------ versions -----

# "7.3.1" -> "7.3", "7.4-rc1" -> "7.4", "7.3" -> "7.3"
lunar_series_of() { local v="${1%%-rc*}"; echo "${v%.*}" | grep -Eo '^[0-9]+\.[0-9]+' || echo "$v"; }

# Patch series linux-lunar ships, e.g. "7.3 7.4"
lunar_supported_series() {
	local where="$1" d out=()
	for d in "$where"/lunar-patches/*/; do
		[[ -f "$d/series" ]] && out+=("$(basename "$d")")
	done
	printf '%s\n' "${out[@]}" | sort -V
}

# kernel.org releases.json (cached for one hour)
_lunar_releases_json() {
	local cache="$1/.lunar-releases.json"
	if [[ ! -s "$cache" || -n "$(find "$cache" -mmin +60 2>/dev/null)" ]]; then
		if curl -fsSL --retry 2 https://www.kernel.org/releases.json -o "$cache.tmp"; then
			mv "$cache.tmp" "$cache"
		else
			rm -f "$cache.tmp"
			[[ -s "$cache" ]] || return 1
			_l_warn "kernel.org unreachable, using cached release list"
		fi
	fi
	cat "$cache"
}

# Print "version moniker" for every current kernel.org release.
lunar_current_releases() {
	_lunar_releases_json "$1" | python3 -c '
import json, sys
for r in json.load(sys.stdin)["releases"]:
    if r["moniker"] != "linux-next":
        print(r["version"], r["moniker"])'
}

# Resolve "7.3" to the newest 7.3.x (or 7.3-rcN while 7.3 is in development).
lunar_resolve_series() {
	local where="$1" series="$2" v best=""
	while read -r v _; do
		[[ "$v" == "$series" || "$v" == "$series".* || "$v" == "$series"-rc* ]] || continue
		best="$v"
	done < <(lunar_current_releases "$where" | sort -V)
	[[ -n "$best" ]] || return 1
	echo "$best"
}

# Set _kver, _kseries, _srcname, _src_url, _sig_url from a concrete version.
lunar_version_urls() {
	local v="$1" major
	_kseries="$(lunar_series_of "$v")"
	major="${_kseries%%.*}"
	if [[ "$v" =~ ^[0-9]+\.[0-9]+-rc[0-9]+$ ]]; then
		_kver="$v"
		_srcname="linux-$v"
		_src_url="https://git.kernel.org/torvalds/t/linux-$v.tar.gz"
		_sig_url=""
	elif [[ "$v" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
		[[ "$v" =~ \.0$ ]] && v="${v%.0}"
		_kver="$v"
		_srcname="linux-$v"
		_src_url="https://cdn.kernel.org/pub/linux/kernel/v$major.x/linux-$v.tar.xz"
		_sig_url="https://cdn.kernel.org/pub/linux/kernel/v$major.x/linux-$v.tar.sign"
	else
		_l_die "Cannot understand kernel version '$1' (use e.g. 7.3, 7.3.1 or 7.4-rc1)"
	fi
}

# ------------------------------------------------------------ patch lists --

# Fill _lunar_patches with the enabled patches of the series (relative paths).
lunar_collect_patches() {
	local where="$1" series="$2" var file
	_lunar_patches=()
	[[ -f "$where/lunar-patches/$series/series" ]] || return 0
	while read -r var file; do
		[[ -z "$var" || "$var" == \#* ]] && continue
		[[ -f "$where/lunar-patches/$series/$file" ]] \
			|| _l_die "lunar-patches/$series/series names missing file $file"
		if _l_true "${!var}"; then
			_lunar_patches+=("lunar-patches/$series/$file")
		fi
	done < "$where/lunar-patches/$series/series"
}

# Fill _lunar_userreverts / _lunar_userpatches (relative paths).
lunar_collect_userpatches() {
	local where="$1" series="$2" dir f
	dir="linux${series//./}-lunar-userpatches"
	_lunar_userreverts=() _lunar_userpatches=()
	_l_true "$_user_patches" || return 0
	[[ -d "$where/$dir" ]] || return 0
	for f in "$where/$dir"/*.myrevert; do [[ -e "$f" ]] && _lunar_userreverts+=("$dir/${f##*/}"); done
	for f in "$where/$dir"/*.mypatch;  do [[ -e "$f" ]] && _lunar_userpatches+=("$dir/${f##*/}"); done
	for f in "$where/$dir"/*.patch;    do [[ -e "$f" ]] && _l_warn "Ignoring $dir/${f##*/}: user patches must end in .mypatch or .myrevert"; done
	return 0
}

# ------------------------------------------------------- prepare() steps ----

_l_patch() { # file [-R]
	local f="$1" rev="${2:-}"
	_l_msg2 "${rev:+Reverting}${rev:-Applying} ${f##*/}"
	patch -Np1 ${rev:+-R} --no-backup-if-mismatch --fuzz="${_lunar_fuzz:-0}" -i "$f" \
		|| _l_die "${f##*/} does not apply to $_srcname. Nothing was built."
}

lunar_apply_patches() {
	local where="$1" f
	if (( ${#_lunar_userreverts[@]} )); then
		_l_msg "Reverting user patches"
		for f in "${_lunar_userreverts[@]}"; do _lunar_fuzz=2 _l_patch "$where/$f" -R; done
	fi
	if (( ${#_lunar_patches[@]} )); then
		_l_msg "Applying lunar patches"
		for f in "${_lunar_patches[@]}"; do _l_patch "$where/$f"; done
	else
		_l_warn "No lunar patches enabled"
	fi
	if (( ${#_lunar_userpatches[@]} )); then
		_l_msg "Applying user patches"
		for f in "${_lunar_userpatches[@]}"; do _lunar_fuzz=2 _l_patch "$where/$f"; done
	fi
}

# Replace exactly one source line matching regex $2 in file $1 with $3
# (\t in $3 becomes a tab). Dies unless exactly one line matches.
_l_set_line() {
	python3 - "$@" <<'PY' || _l_die "Cannot set default in $1 (pattern: $2)"
import re, sys
path, pattern, new = sys.argv[1], sys.argv[2], sys.argv[3].replace("\\t", "\t")
src = open(path).read()
rx = re.compile(pattern, re.M)
n = len(rx.findall(src))
if n != 1:
    sys.exit(f"  expected exactly one line matching, found {n}")
open(path, "w").write(rx.sub(lambda m: new, src))
PY
}

# Compile the chosen defaults into the source. Every value stays tunable.
lunar_set_defaults() {
	_l_msg "Setting compiled-in defaults"
	if [[ -n "$_default_defrag_mode" ]]; then
		_l_msg2 "vm.defrag_mode = $_default_defrag_mode"
		_l_set_line mm/page_alloc.c '^int defrag_mode( = [0-9]+)?;$' "int defrag_mode = $_default_defrag_mode;"
	fi
	if [[ -n "$_default_watermark_scale_factor" ]]; then
		_l_msg2 "vm.watermark_scale_factor = $_default_watermark_scale_factor"
		_l_set_line mm/page_alloc.c '^static int watermark_scale_factor = [0-9]+;$' \
			"static int watermark_scale_factor = $_default_watermark_scale_factor;"
	fi
	if [[ -n "$_default_watermark_boost_factor" ]]; then
		_l_msg2 "vm.watermark_boost_factor = $_default_watermark_boost_factor"
		_l_set_line mm/page_alloc.c '^static int watermark_boost_factor __read_mostly = [0-9]+;$' \
			"static int watermark_boost_factor __read_mostly = $_default_watermark_boost_factor;"
	fi
	if [[ -n "$_default_compaction_proactiveness" ]]; then
		_l_msg2 "vm.compaction_proactiveness = $_default_compaction_proactiveness"
		_l_set_line mm/compaction.c '^static unsigned int __read_mostly sysctl_compaction_proactiveness = [0-9]+;$' \
			"static unsigned int __read_mostly sysctl_compaction_proactiveness = $_default_compaction_proactiveness;"
	fi
	if [[ -n "$_default_swappiness" ]]; then
		_l_msg2 "vm.swappiness = $_default_swappiness"
		_l_set_line mm/vmscan.c '^int vm_swappiness = [0-9]+;$' "int vm_swappiness = $_default_swappiness;"
	fi
	if _l_true "$_default_ttm_low_latency"; then
		_l_msg2 "ttm.low_latency_alloc = Y"
		_l_set_line drivers/gpu/drm/ttm/ttm_pool.c '^static bool ttm_pool_low_latency;$' \
			'static bool ttm_pool_low_latency = true;'
	fi

	local flag
	case "$_thp_defrag" in
		always)        flag='(1<<TRANSPARENT_HUGEPAGE_DEFRAG_DIRECT_FLAG)|' ;;
		defer)         flag='(1<<TRANSPARENT_HUGEPAGE_DEFRAG_KSWAPD_FLAG)|' ;;
		defer+madvise) flag='(1<<TRANSPARENT_HUGEPAGE_DEFRAG_KSWAPD_OR_MADV_FLAG)|' ;;
		madvise)       flag='(1<<TRANSPARENT_HUGEPAGE_DEFRAG_REQ_MADV_FLAG)|' ;;
		never)         flag='/* lunar: defrag=never */' ;;
	esac
	_l_msg2 "transparent_hugepage/defrag = $_thp_defrag"
	_l_set_line mm/huge_memory.c '^\t\(1<<TRANSPARENT_HUGEPAGE_DEFRAG_REQ_MADV_FLAG\)\|$' "\t$flag"
}

# Kconfig helpers
_l_cfg() { scripts/config --file .config "$@"; }

lunar_configure() {
	local where="$1"
	_l_msg "Configuring"

	[[ -s "$where/.lunar-base.config" ]] || _l_die "Base config missing, run ./lunar.sh"
	cp "$where/.lunar-base.config" .config

	_l_cfg --set-str LOCALVERSION "" -d LOCALVERSION_AUTO
	_l_cfg -e IKCONFIG -e IKCONFIG_PROC   # lets _base_config="running" reuse this kernel's config

	# compiler / LTO
	case "$_lto_mode" in
		none) _l_cfg -e LTO_NONE -d LTO_CLANG_THIN -d LTO_CLANG_FULL ;;
		thin) _l_cfg -d LTO_NONE -e LTO_CLANG_THIN -d LTO_CLANG_FULL ;;
		full) _l_cfg -d LTO_NONE -d LTO_CLANG_THIN -e LTO_CLANG_FULL ;;
	esac

	# CPU
	case "$_march" in
		native)  _l_cfg -e X86_NATIVE_CPU ;;
		*)       _l_cfg -d X86_NATIVE_CPU ;;
	esac

	# timer
	_l_cfg -d HZ_100 -d HZ_250 -d HZ_300 -d HZ_1000 -e "HZ_$_timer_freq" --set-val HZ "$_timer_freq"

	# preemption
	case "$_preempt" in
		lazy) _l_cfg -d PREEMPT -e PREEMPT_LAZY -d PREEMPT_RT ;;
		full) _l_cfg -e PREEMPT -d PREEMPT_LAZY -d PREEMPT_RT ;;
		rt)   _l_cfg -e EXPERT -d PREEMPT -d PREEMPT_LAZY -e PREEMPT_RT ;;
	esac
	if _l_true "$_preempt_dynamic"; then _l_cfg -e PREEMPT_DYNAMIC; else _l_cfg -d PREEMPT_DYNAMIC; fi

	# ticks
	case "$_tickless" in
		periodic) _l_cfg -d NO_HZ_IDLE -d NO_HZ_FULL -d NO_HZ -d NO_HZ_COMMON -e HZ_PERIODIC ;;
		idle)     _l_cfg -d HZ_PERIODIC -d NO_HZ_FULL -e NO_HZ_IDLE -e NO_HZ -e NO_HZ_COMMON ;;
		full)     _l_cfg -d HZ_PERIODIC -d NO_HZ_IDLE -d CONTEXT_TRACKING_FORCE -e NO_HZ_FULL -e NO_HZ -e NO_HZ_COMMON -e CONTEXT_TRACKING ;;
	esac

	[[ -n "$_nr_cpus" ]] && _l_cfg --set-val NR_CPUS "$_nr_cpus"

	# memory: what the lunar patches and their measurement tools rely on
	_l_cfg -e TRANSPARENT_HUGEPAGE -e COMPACTION -e MIGRATION -e PSI -d PSI_DEFAULT_DISABLED \
	       -e SWAP -e MEMCG
	case "$_thp_enabled" in
		always)  _l_cfg -e TRANSPARENT_HUGEPAGE_ALWAYS -d TRANSPARENT_HUGEPAGE_MADVISE -d TRANSPARENT_HUGEPAGE_NEVER ;;
		madvise) _l_cfg -d TRANSPARENT_HUGEPAGE_ALWAYS -e TRANSPARENT_HUGEPAGE_MADVISE -d TRANSPARENT_HUGEPAGE_NEVER ;;
		never)   _l_cfg -d TRANSPARENT_HUGEPAGE_ALWAYS -d TRANSPARENT_HUGEPAGE_MADVISE -e TRANSPARENT_HUGEPAGE_NEVER ;;
	esac
	if _l_true "$_mglru"; then _l_cfg -e LRU_GEN -e LRU_GEN_ENABLED; else _l_cfg -d LRU_GEN_ENABLED; fi

	make "${BUILD_FLAGS[@]}" olddefconfig >/dev/null

	if _l_true "$_localmodconfig"; then
		local lsmod_file
		if [[ -s "$_modprobeddb_path" ]]; then
			lsmod_file="$_modprobeddb_path"
			_l_msg2 "localmodconfig with modprobed-db ($lsmod_file)"
		else
			lsmod_file="$(mktemp)"
			lsmod > "$lsmod_file"
			_l_warn "No modprobed-db database at $_modprobeddb_path; using the currently loaded modules only"
		fi
		yes "" | make "${BUILD_FLAGS[@]}" LSMOD="$lsmod_file" localmodconfig >/dev/null
		[[ "$lsmod_file" == "$_modprobeddb_path" ]] || rm -f "$lsmod_file"
	fi

	if [[ "$_menuconfig" != none ]]; then
		make "${BUILD_FLAGS[@]}" "$_menuconfig"
	fi
	make "${BUILD_FLAGS[@]}" olddefconfig >/dev/null

	lunar_check_config
	make -s kernelrelease > version
	_l_msg2 "Kernel release: $(<version)"
	cp .config "$where/lunar-config/last-config-$(<version)"
	_l_msg2 "Final config saved as lunar-config/last-config-$(<version)"
}

# Warn when Kconfig silently dropped a choice (missing dependency etc.).
lunar_check_config() {
	local want=() w
	want+=("CONFIG_HZ=$_timer_freq")
	case "$_lto_mode" in
		thin) want+=(CONFIG_LTO_CLANG_THIN=y) ;;
		full) want+=(CONFIG_LTO_CLANG_FULL=y) ;;
	esac
	case "$_preempt" in
		lazy) want+=(CONFIG_PREEMPT_LAZY=y) ;;
		full) want+=(CONFIG_PREEMPT=y) ;;
		rt)   want+=(CONFIG_PREEMPT_RT=y) ;;
	esac
	[[ "$_march" == native ]] && want+=(CONFIG_X86_NATIVE_CPU=y)
	want+=("CONFIG_TRANSPARENT_HUGEPAGE_${_thp_enabled^^}=y" CONFIG_COMPACTION=y CONFIG_PSI=y)
	_l_true "$_mglru" && want+=(CONFIG_LRU_GEN_ENABLED=y)
	for w in "${want[@]}"; do
		grep -qx "$w" .config || _l_warn "Wanted $w, but Kconfig did not keep it (missing dependency?)"
	done
}

# Full prepare() sequence.
lunar_prepare() {
	local where="$1"
	_l_msg "Preparing $_srcname for $pkgbase"
	echo "-${pkgrel}" > localversion.10-pkgrel
	echo "-${_pkgsuffix}${_localversion}" > localversion.20-pkgname
	lunar_apply_patches "$where"
	lunar_set_defaults
	lunar_configure "$where"
}
