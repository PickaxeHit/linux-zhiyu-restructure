# The vendor ramdisk: /init, the boot-time modules, firmware, and the small
# static helpers.  Mirrors initramfs-src/build.sh, but every input is a
# derivation instead of a file that happens to be on the build host.
#
# Everything here is a native aarch64 build.  The helpers and fsck are static
# because the early boot environment has no Nix store, not because of cross
# compilation; the tools used to assemble the ramdisk (cpio, depmod, python3,
# zstd) are ordinary native build inputs.
{
  lib,
  stdenv,
  autoreconfHook,
  busybox,
  cpio,
  kmod,
  python3,
  zstd,
  f2fs-tools,
  firmware,
  kernel,
  keymint ? null,
  appletsFile ? ../initramfs-src/busybox-applets.txt,
  modulesFile ? ../initramfs-src/modules.tsv,
  fsDir ? ../initramfs-src/fs,
  helpersDir ? ../initramfs-src/src,
}:

let
  inherit (stdenv) cc;

  ver = kernel.modDirVersion;

  # nixpkgs' busybox with CONFIG_STATIC; it also carries the CVE patches for
  # 1.37.0, which is why the version is not pinned here.
  staticBusybox = busybox.override { enableStatic = true; };

  # Fully static fsck.f2fs: the initramfs runs it against a dirty
  # metadata-encrypted userdata device before the rw mount, so it cannot
  # depend on anything from the rootfs.  Source and patches are nixpkgs'
  # (kernel.org snapshot, includes the C23 patch), so no -std=gnu17 hack.
  fsckf2fs = stdenv.mkDerivation {
    pname = "fsck.f2fs-static";
    inherit (f2fs-tools) version src patches;

    nativeBuildInputs = [ autoreconfHook ];
    hardeningDisable = [ "all" ];

    configurePhase = ''
      runHook preConfigure
      # Every optional dependency off: with libuuid/libselinux/liblz4 present,
      # configure compiles in calls the static link would then have to resolve
      # from libraries that are not in the ramdisk.
      ./configure --host=${stdenv.hostPlatform.config} \
        --disable-shared --enable-static \
        --without-selinux --without-blkid --without-lz4 --without-lzo2 \
        ac_cv_lib_uuid_uuid_clear=no ac_cv_header_uuid_uuid_h=no
      runHook postConfigure
    '';

    buildPhase = ''
      runHook preBuild
      make -j''${NIX_BUILD_CORES:-1}
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      # libtool links a dynamic binary even with LDFLAGS=-static; link the
      # just-built objects against the static convenience library by hand.
      $CC -static -o $out/bin/fsck.f2fs -L${cc.libc.static}/lib \
        fsck/*.o lib/.libs/libf2fs.a -lpthread
      runHook postInstall
    '';
  };
in
stdenv.mkDerivation {
  pname = "zhiyu-initramfs";
  inherit (kernel) version;

  dontUnpack = true;

  nativeBuildInputs = [
    cpio
    kmod
    python3
    zstd
  ];

  buildCommand = ''
    stage=$PWD/stage
    mkdir -p $stage/{bin,dev/pts,etc/modprobe.d,lib/firmware,lib/modules/${ver},proc,root,run,sys,tmp,libexec}

    # ---- /init and its helpers -------------------------------------------
    install -m0755 ${fsDir}/init $stage/init
    install -m0755 ${fsDir}/libexec/metadata-root $stage/libexec/metadata-root

    # ---- busybox + the applets the init script uses ----------------------
    # Only the binary and the applet list are copied: everything else in the
    # package's bin/ is a symlink whose target the ramdisk may not carry.
    install -m0755 ${staticBusybox}/bin/busybox $stage/bin/busybox
    while read -r applet; do
      [ -n "$applet" ] || continue
      ln -sf busybox "$stage/bin/$applet"
    done < ${appletsFile}

    # ---- our static helpers (btaddr, charger, userdata-map) --------------
    for src in ${helpersDir}/*.c; do
      install -m0644 "$src" .
      $CC -static -Os -Wall -Wextra -L${cc.libc.static}/lib \
        -o "$stage/bin/$(basename "$src" .c)" "$(basename "$src")"
    done

    # ---- fsck.f2fs --------------------------------------------------------
    install -m0755 ${fsckf2fs}/bin/fsck.f2fs $stage/bin/fsck.f2fs

    ${lib.optionalString (keymint != null) ''
      cp -a ${keymint}/bin/. $stage/bin/
      # cp -a copies the store directory's mode onto $stage/bin as well.
      chmod -R u+w $stage/bin
    ''}

    # ---- busybox applet check --------------------------------------------
    # The build is native, so busybox can be asked which applets it actually
    # has; creating a symlink for a missing applet would only fail at boot.
    applets=$(${staticBusybox}/bin/busybox --list)
    for applet in $(cat ${appletsFile}) \
      sh mount umount insmod switch_root sleep grep sed cat mkdir mknod dmesg \
      head tail tr cut printf basename dirname seq; do
      printf '%s\n' "$applets" | grep -qx "$applet" || {
        echo "busybox does not provide the $applet applet" >&2
        exit 1
      }
      [ -e "$stage/bin/$applet" ] || ln -sf busybox "$stage/bin/$applet"
    done

    # ---- self-containment ------------------------------------------------
    # The ramdisk runs before udev and before any rootfs, so every binary must
    # be a static AArch64 executable and the applets the init script uses must
    # actually exist.
    # $READELF is the target binutils reader, which runs on the build host.
    check_binary() {
      if $READELF -l "$1" | grep -q INTERP || $READELF -d "$1" | grep -q NEEDED; then
        echo "$1 is dynamically linked" >&2
        exit 1
      fi
      $READELF -h "$1" | grep -q 'Machine:.*AArch64' || {
        echo "$1 is not AArch64" >&2
        exit 1
      }
    }
    for binary in busybox fsck.f2fs btaddr charger userdata-map; do
      check_binary "$stage/bin/$binary"
    done
    # ---- firmware + audio topology ---------------------------------------
    cp -a ${firmware}/lib/firmware/. $stage/lib/firmware/
    chmod -R u+w $stage/lib/firmware

    # ---- kernel modules, at the paths init expects ------------------------
    moddir=$stage/lib/modules/${ver}
    while IFS=$'\t' read -r rel src; do
      [ -n "$rel" ] || continue
      case "$rel" in \#*) continue ;; esac
      install -Dm0644 ${kernel.modules}/lib/modules/${ver}/kernel/"$src" "$moddir/$rel"
    done < ${modulesFile}

    # depmod builds the dependency graph, order-modules.py turns it into the
    # load order init walks (see initramfs-src/order-modules.py).
    depmod -b $stage ${ver}
    python3 ${../initramfs-src/order-modules.py} "$moddir" > "$moddir/load-order"

    # cpio records each file's mtime and emits entries in readdir order; pin
    # both so the ramdisk is a function of the inputs only.
    find $stage -exec touch -h -d @''${SOURCE_DATE_EPOCH:-0} {} +
    mkdir -p $out
    ( cd $stage && find . -print0 | sort -z \
        | cpio --null -o --format=newc --owner=0:0 --reproducible --quiet \
        | zstd -19 -T0 --no-progress ) > $out/initramfs.cpio.zst

    echo "bin: $(ls $stage/bin | wc -l)  modules: $(wc -l < "$moddir/load-order")"
    echo "ramdisk: $(stat -c %s $out/initramfs.cpio.zst) bytes"
  '';

  meta = {
    description = "Vendor ramdisk for the Lenovo TB378FC";
    platforms = lib.platforms.linux;
  };
}
