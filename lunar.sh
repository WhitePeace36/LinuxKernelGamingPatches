#!/usr/bin/env bash
# linux-lunar - build a gaming kernel with the lunar memory-stall patches.
#
#   ./lunar.sh               resolve options, build and install (makepkg -si)
#   ./lunar.sh --build-only  build the packages, do not install them
#   ./lunar.sh --prepare     only download, patch and configure (inspect src/)
#   ./lunar.sh --list        show kernel versions and the patch sets available
#   ./lunar.sh --clean       remove build files (src/, pkg/, packages, caches)
#   Anything after "--" is passed to makepkg, e.g. ./lunar.sh -- --skippgpcheck
set -euo pipefail

_where="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
cd "$_where"
# shellcheck source=lunar-config/lib.sh
source "$_where/lunar-config/lib.sh"

# ------------------------------------------------------------ cleanup -------

# Remove what an interrupted or failed run leaves behind. Finished packages
# and a completely downloaded kernel tarball are kept.
_lunar_cleanup_abort() {
	rm -f .lunar-base.config.tmp .lunar-releases.json.tmp ./*.part
	if _l_true "${_cleanup_on_abort:-true}"; then
		rm -rf src pkg .lunar-build.cfg
		_l_msg2 "Removed src/, pkg/ and partial downloads"
	else
		_l_msg2 "Kept src/ and pkg/ (_cleanup_on_abort=false)"
	fi
}

# Signal every process started by this script (makepkg, make, compilers...),
# deepest first. Processes running as root (pacman via sudo) are left alone:
# interrupting a package installation half-way is worse than letting it end.
# Child PIDs of $1, without the subshell that runs this function.
_lunar_children() { pgrep -P "$1" 2>/dev/null | grep -vx "$BASHPID" || true; }

_lunar_kill_tree() {
	local sig="$1" pid="$2" child
	for child in $(_lunar_children "$pid"); do
		_lunar_kill_tree "$sig" "$child"
	done
	[[ "$pid" == "$$" ]] && return 0
	[[ "$(stat -c %u "/proc/$pid" 2>/dev/null)" == "$EUID" ]] || return 0
	kill "-$sig" "$pid" 2>/dev/null || true
}

_lunar_on_signal() {
	local sig="$1"
	trap '' INT TERM HUP QUIT
	echo
	_l_warn "Interrupted (SIG$sig), stopping the build"
	_lunar_kill_tree TERM "$$"
	# give make/compilers a moment, then make sure nothing is left
	local i
	for i in 1 2 3 4 5 6 7 8 9 10; do
		[[ -z "$(_lunar_children "$$")" ]] && break
		sleep 0.5
	done
	_lunar_kill_tree KILL "$$"
	wait 2>/dev/null || true
	_lunar_cleanup_abort
	case "$sig" in INT) exit 130 ;; TERM) exit 143 ;; HUP) exit 129 ;; *) exit 131 ;; esac
}
trap '_lunar_on_signal INT' INT
trap '_lunar_on_signal TERM' TERM
trap '_lunar_on_signal HUP' HUP
trap '_lunar_on_signal QUIT' QUIT

_mode="install"
_makepkg_extra=()
while (( $# )); do
	case "$1" in
		--build-only) _mode="build" ;;
		--prepare)    _mode="prepare" ;;
		--list)       _mode="list" ;;
		--clean)      _mode="clean" ;;
		-h|--help)    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		--)           shift; _makepkg_extra=("$@"); break ;;
		*)            _l_die "Unknown option $1 (see --help)" ;;
	esac
	shift
done

if [[ "$_mode" == clean ]]; then
	rm -rf src pkg ./*.pkg.tar.* ./*.part .lunar-build.cfg .lunar-base.config .lunar-base.config.tmp \
		.lunar-releases.json .lunar-releases.json.tmp
	_l_msg "Cleaned"
	exit 0
fi

(( EUID != 0 )) || _l_die "Do not run as root; makepkg asks for sudo when installing"

lunar_load_options "$_where"
mapfile -t _series_list < <(lunar_supported_series "$_where")

if [[ "$_mode" == list ]]; then
	_l_msg "Patch sets in lunar-patches/: ${_series_list[*]}"
	_l_msg "Current kernel.org releases"
	while read -r v m; do
		s="$(lunar_series_of "$v")"
		if _l_in "$s" "${_series_list[@]}"; then tag="lunar patches"; else tag="no lunar patches"; fi
		printf '  %-14s %-10s %s\n' "$v" "$m" "$tag"
	done < <(lunar_current_releases "$_where" | sort -V)
	exit 0
fi

_ask() { # question default -> REPLY
	if _l_true "$_noninteractive"; then REPLY="$2"; return; fi
	read -rp "$(printf '\033[1;32m::\033[0m %s ' "$1")" REPLY
	REPLY="${REPLY:-$2}"
}

# ------------------------------------------------------------ version -------

if [[ -z "$_version" ]]; then
	_l_true "$_noninteractive" && _l_die "_version is empty and _noninteractive is set"
	_l_msg "Which kernel?"
	_choices=()
	while read -r v m; do
		_l_in "$(lunar_series_of "$v")" "${_series_list[@]}" || continue
		_choices+=("$v ($m)")
	done < <(lunar_current_releases "$_where" | sort -V) || true
	if (( ${#_choices[@]} == 0 )); then
		_l_warn "Could not get the release list from kernel.org"
		_ask "Kernel version (e.g. ${_series_list[-1]}):" ""
		_version="$REPLY"
	else
		for i in "${!_choices[@]}"; do printf '  %d) %s\n' "$((i + 1))" "${_choices[$i]}"; done
		_ask "Number or version [${#_choices[@]}]:" "${#_choices[@]}"
		if [[ "$REPLY" =~ ^[0-9]+$ ]] && (( REPLY >= 1 && REPLY <= ${#_choices[@]} )); then
			_version="${_choices[$((REPLY - 1))]%% *}"
		else
			_version="$REPLY"
		fi
	fi
fi

if [[ "$_version" =~ ^[0-9]+\.[0-9]+$ ]]; then
	_l_msg2 "Looking up the newest $_version release on kernel.org"
	_resolved="$(lunar_resolve_series "$_where" "$_version")" \
		|| _l_die "kernel.org lists no current $_version release (end of life?). Set an exact version like $_version.1"
	_version="$_resolved"
fi
lunar_version_urls "$_version"

if ! _l_in "$_kseries" "${_series_list[@]}"; then
	_l_die "No lunar patches for $_kseries (available: ${_series_list[*]})"
fi

lunar_validate_options

# ------------------------------------------------------------ patches -------

lunar_collect_patches "$_where" "$_kseries"
lunar_collect_userpatches "$_where" "$_kseries"
if (( ${#_lunar_userreverts[@]} + ${#_lunar_userpatches[@]} )) && _l_true "$_user_patches_confirm"; then
	_l_msg "User patches found for $_kseries:"
	for _f in "${_lunar_userreverts[@]}"; do printf '  revert: %s\n' "$_f"; done
	for _f in "${_lunar_userpatches[@]}"; do printf '  apply:  %s\n' "$_f"; done
	_ask "Use them? [Y/n]" "y"
	if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then _lunar_userreverts=(); _lunar_userpatches=(); fi
fi

# ------------------------------------------------------------ base config ---

_l_msg "Base config: $_base_config"
case "$_base_config" in
	arch)
		curl -fsSL --retry 2 -o .lunar-base.config.tmp \
			"https://gitlab.archlinux.org/archlinux/packaging/packages/linux/-/raw/main/config.x86_64" \
			|| { rm -f .lunar-base.config.tmp; _l_die "Could not download Arch's config"; }
		mv .lunar-base.config.tmp .lunar-base.config ;;
	cachyos)
		curl -fsSL --retry 2 -o .lunar-base.config.tmp \
			"https://raw.githubusercontent.com/CachyOS/linux-cachyos/master/linux-cachyos/config" \
			|| { rm -f .lunar-base.config.tmp; _l_die "Could not download CachyOS's config"; }
		mv .lunar-base.config.tmp .lunar-base.config ;;
	running)
		[[ -r /proc/config.gz ]] || _l_die "/proc/config.gz not available (CONFIG_IKCONFIG_PROC off)"
		zcat /proc/config.gz > .lunar-base.config ;;
	*)
		[[ -r "$_base_config" ]] || _l_die "Config file $_base_config not found"
		cp "$_base_config" .lunar-base.config ;;
esac
grep -q '^CONFIG_' .lunar-base.config || _l_die "Base config looks empty"

# ------------------------------------------------------------ summary -------

# makepkg sources the PKGBUILD inside a function, so every variable is
# declared global (-g) explicitly.
_globalize() { sed -E 's/^declare -- /declare -g /; t; s/^declare -([a-zA-Z]+) /declare -g\1 /'; }
{
	echo "# Generated by lunar.sh on $(date -R). Do not edit; edit customization.cfg."
	for _o in "${_LUNAR_OPTIONS[@]}"; do declare -p "$_o" 2>/dev/null || echo "declare -g $_o=''"; done
	declare -p _kver _kseries _srcname _src_url _sig_url _lunar_patches _lunar_userreverts _lunar_userpatches
} | _globalize > .lunar-build.cfg

_l_msg "linux-$_pkgsuffix $_kver"
_l_msg2 "compiler $_compiler, LTO $_lto_mode, -march=$_march, ${_timer_freq} Hz, preempt $_preempt, ticks $_tickless"
_l_msg2 "THP $_thp_enabled/$_thp_defrag, MGLRU $_mglru"
_l_msg2 "defaults: defrag_mode=${_default_defrag_mode:-kernel} scale=${_default_watermark_scale_factor:-kernel} boost=${_default_watermark_boost_factor:-kernel} proactiveness=${_default_compaction_proactiveness:-kernel} swappiness=${_default_swappiness:-kernel} ttm.low_latency=${_default_ttm_low_latency}"
_l_msg2 "lunar patches: ${#_lunar_patches[@]}, user patches: $(( ${#_lunar_userreverts[@]} + ${#_lunar_userpatches[@]} ))"

# ------------------------------------------------------------ makepkg -------

_mk=(makepkg --cleanbuild --syncdeps)
_l_true "$_pgp_verify" || _mk+=(--skippgpcheck)
case "$_mode" in
	install) _mk+=(--install --force) ;;
	build)   _mk+=(--force) ;;
	prepare) _mk+=(--nobuild) ;;
esac
_l_msg "Running ${_mk[*]} ${_makepkg_extra[*]}"
# makepkg runs in the background and the script waits with the `wait`
# builtin: bash only runs signal traps between commands, and `wait` is the one
# place where a trap interrupts it at once. stdin is passed on explicitly,
# otherwise a background job reads /dev/null and sudo/pacman cannot ask.
exec {_lunar_stdin}<&0
"${_mk[@]}" "${_makepkg_extra[@]}" <&"$_lunar_stdin" &
_lunar_mk_pid=$!
_rc=0
wait "$_lunar_mk_pid" || _rc=$?

if (( _rc != 0 )); then
	_l_warn "makepkg failed (exit code $_rc)"
	_lunar_cleanup_abort
	exit "$_rc"
fi

if [[ "$_mode" != prepare ]] && _l_true "$_cleanup_after_build"; then
	rm -rf src pkg ./*.part
	_l_msg2 "Removed src/ and pkg/ (packages kept: $(echo ./*.pkg.tar.* | tr ' ' '\n' | sed 's|^\./||' | paste -sd ' '))"
fi
_l_msg "Done"
