# linux-lunar PKGBUILD - run ./lunar.sh instead of makepkg directly.
# Packaging follows the structure of Arch Linux's linux package.

_lunar_where="${startdir:-$PWD}"
if [[ ! -f "$_lunar_where/.lunar-build.cfg" ]]; then
	echo "==> ERROR: run ./lunar.sh, it resolves customization.cfg first" >&2
	exit 1
fi
# shellcheck disable=SC1091
source "$_lunar_where/.lunar-build.cfg"
# shellcheck disable=SC1091
source "$_lunar_where/lunar-config/lib.sh"

pkgbase="linux-${_pkgsuffix}"
pkgname=("$pkgbase")
_l_true "$_build_headers" && pkgname+=("$pkgbase-headers")
pkgver="${_kver//-/}"           # 7.4-rc1 -> 7.4rc1 (pacman versions cannot contain '-')
pkgrel=1
pkgdesc="Linux kernel with the lunar memory-stall patches"
url="https://www.kernel.org/"
arch=(x86_64)
license=(GPL-2.0-only)
makedepends=(bc cpio gettext libelf pahole perl python tar xz zstd)
options=('!strip' '!debug' '!lto')

source=("$_srcname.tar.${_src_url##*.tar.}::$_src_url")
sha256sums=(SKIP)
if [[ -n "$_sig_url" ]] && _l_true "$_pgp_verify"; then
	source+=("$_srcname.tar.sign::$_sig_url")
	sha256sums+=(SKIP)
fi
validpgpkeys=(
	ABAF11C65A2970B130ABE3C479BE3E4300411886  # Linus Torvalds
	647F28654894E3BD457199BE38DBBDC86092693E  # Greg Kroah-Hartman
)

BUILD_FLAGS=()
if [[ "$_compiler" == llvm ]]; then
	makedepends+=(clang llvm lld)
	BUILD_FLAGS=(CC=clang LD=ld.lld LLVM=1 LLVM_IAS=1)
fi
_l_true "$_localmodconfig" && makedepends+=(kmod)
[[ "$_menuconfig" == xconfig ]] && makedepends+=(qt6-base)

_lunar_kcflags="$_kcflags"
if [[ "$_march" != native && "$_march" != generic ]]; then
	_lunar_kcflags="-march=$_march $_lunar_kcflags"
fi

export KBUILD_BUILD_HOST=lunar
export KBUILD_BUILD_USER="$pkgbase"
export KBUILD_BUILD_TIMESTAMP="$(date -Ru${SOURCE_DATE_EPOCH:+d @$SOURCE_DATE_EPOCH})"

prepare() {
	cd "$_srcname"
	lunar_prepare "$_lunar_where"
}

build() {
	cd "$_srcname"
	make "${BUILD_FLAGS[@]}" KCFLAGS="$_lunar_kcflags" -j"${_jobs:-$(nproc)}" all
}

_package() {
	pkgdesc="$pkgdesc (kernel and modules)"
	depends=(coreutils kmod initramfs)
	optdepends=('wireless-regdb: to set the correct wireless channels of your country'
	            'linux-firmware: firmware images needed for some devices'
	            'modprobed-db: track used modules for _localmodconfig')
	provides=(KSMBD-MODULE NTSYNC-MODULE VIRTUALBOX-GUEST-MODULES WIREGUARD-MODULE)

	cd "$_srcname"
	local modulesdir="$pkgdir/usr/lib/modules/$(<version)"

	echo "Installing boot image..."
	# systemd and mkinitcpio find the kernel here
	install -Dm644 "$(make -s image_name)" "$modulesdir/vmlinuz"
	# used by mkinitcpio to name the kernel and initramfs
	echo "$pkgbase" | install -Dm644 /dev/stdin "$modulesdir/pkgbase"

	echo "Installing modules..."
	ZSTD_CLEVEL=19 make "${BUILD_FLAGS[@]}" INSTALL_MOD_PATH="$pkgdir/usr" INSTALL_MOD_STRIP=1 \
		DEPMOD=/doesnt/exist modules_install
	rm -f "$modulesdir"/build
}

_package-headers() {
	pkgdesc="$pkgdesc (headers and scripts for building modules)"
	depends=(pahole "$pkgbase")
	provides=(LINUX-HEADERS)
	[[ "$_compiler" == llvm ]] && depends+=(clang llvm lld)

	cd "$_srcname"
	local builddir="$pkgdir/usr/lib/modules/$(<version)/build"

	echo "Installing build files..."
	install -Dt "$builddir" -m644 .config Makefile Module.symvers System.map \
		localversion.* version vmlinux
	install -Dt "$builddir/kernel" -m644 kernel/Makefile
	install -Dt "$builddir/arch/x86" -m644 arch/x86/Makefile
	cp -t "$builddir" -a scripts
	ln -srt "$builddir" "$builddir/scripts/gdb/vmlinux-gdb.py" 2>/dev/null || true

	# needed by objtool / BTF when building external modules
	install -Dt "$builddir/tools/objtool" tools/objtool/objtool
	[[ -f tools/bpf/resolve_btfids/resolve_btfids ]] && \
		install -Dt "$builddir/tools/bpf/resolve_btfids" tools/bpf/resolve_btfids/resolve_btfids

	echo "Installing headers..."
	cp -t "$builddir" -a include
	cp -t "$builddir/arch/x86" -a arch/x86/include
	install -Dt "$builddir/arch/x86/kernel" -m644 arch/x86/kernel/asm-offsets.s
	install -Dt "$builddir/drivers/md" -m644 drivers/md/*.h
	install -Dt "$builddir/net/mac80211" -m644 net/mac80211/*.h
	install -Dt "$builddir/drivers/media/i2c" -m644 drivers/media/i2c/msp3400-driver.h
	install -Dt "$builddir/drivers/media/usb/dvb-usb" -m644 drivers/media/usb/dvb-usb/*.h
	install -Dt "$builddir/drivers/media/dvb-frontends" -m644 drivers/media/dvb-frontends/*.h
	install -Dt "$builddir/drivers/media/tuners" -m644 drivers/media/tuners/*.h
	install -Dt "$builddir/drivers/iio/common/hid-sensors" -m644 drivers/iio/common/hid-sensors/*.h

	echo "Installing Kconfig files..."
	find . -name 'Kconfig*' -exec install -Dm644 {} "$builddir/{}" \;

	if compgen -G "rust/*.rmeta" >/dev/null; then install -Dt "$builddir/rust" -m644 rust/*.rmeta; fi
	if compgen -G "rust/*.so" >/dev/null; then install -Dt "$builddir/rust" rust/*.so; fi

	echo "Installing unstripped VDSO..."
	make INSTALL_MOD_PATH="$pkgdir/usr" vdso_install link=

	echo "Removing unneeded architectures..."
	local a
	for a in "$builddir"/arch/*/; do
		[[ $a == */x86/ ]] || rm -r "$a"
	done

	echo "Removing documentation, broken symlinks and loose objects..."
	rm -rf "$builddir/Documentation"
	find -L "$builddir" -type l -delete
	find "$builddir" -type f -name '*.o' -delete

	echo "Stripping build tools..."
	local file
	while read -rd '' file; do
		case "$(file -Sib "$file")" in
			application/x-sharedlib\;*)      strip -v $STRIP_SHARED "$file" ;;
			application/x-archive\;*)        strip -v $STRIP_STATIC "$file" ;;
			application/x-executable\;*)     strip -v $STRIP_BINARIES "$file" ;;
			application/x-pie-executable\;*) strip -v $STRIP_SHARED "$file" ;;
		esac
	done < <(find "$builddir" -type f -perm -u+x ! -name vmlinux -print0)
	strip -v $STRIP_STATIC "$builddir/vmlinux"

	mkdir -p "$pkgdir/usr/src"
	ln -sr "$builddir" "$pkgdir/usr/src/$pkgbase"
}

for _p in "${pkgname[@]}"; do
	eval "package_$_p() {
		$(declare -f "_package${_p#"$pkgbase"}")
		_package${_p#"$pkgbase"}
	}"
done
