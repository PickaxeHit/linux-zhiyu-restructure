# boot / vendor_boot / init_boot / vbmeta, AVB-signed the way the mkbootimg
# scripts do it, but with a fixed AVB salt: avbtool's default salt is
# /dev/urandom, which makes two runs of the same inputs produce different
# images.  RSA PKCS#1 v1.5 itself is deterministic, so with a fixed salt the
# whole set is reproducible.
#
# The four images are separate derivations: changing the command line only
# rebuilds boot + vbmeta, changing the DTB or the ramdisk only rebuilds
# vendor_boot + vbmeta, and init_boot (an empty ramdisk) never rebuilds.
#
# There is one image set, not one per LSM.  NixOS knows which LSM set it is
# going to run, so it passes it in boot.kernelParams and the kernel picks the
# active security modules from there; the old per-variant images only existed
# because the distro packages had to be built before the target system was
# known.
{
  lib,
  stdenv,
  android-tools,
  cpio,
  zstd,
  openssl,
  kernel,
  dtb,
  initramfs,
  avbKey ? ../avb-test-key.pem,
  # Appended to the board's command line: NixOS passes boot.kernelParams here,
  # so `lsm=`, `loglevel=` and friends are simply whatever the system says.
  kernelParams ? [ ],
  # vendor_bootconfig entries.  The kernel only merges keys starting with
  # "kernel." into its command line; everything else is only readable from
  # /proc/bootconfig.
  bootconfig ? [ ],
}:

let
  pagesize = 4096;

  partitions = {
    boot = 100663296; # 96 MiB
    vendor_boot = 100663296; # 96 MiB
    init_boot = 8388608; # 8 MiB
  };

  osVersion = "15";
  osPatch = "2025-06-05";

  # 32 zero bytes; avbtool wants it as 64 hex characters.
  salt = lib.concatStrings (lib.replicate 64 "0");

  # Board defaults only: everything a NixOS system wants to say about its own
  # security modules or log level comes afterwards, through kernelParams.
  boardCmdline =
    "qcom_ice.use_wrapped_keys=1 rdinit=/init bootconfig console=tty0"
    + " log_buf_len=4M keep_bootcon fbcon=nodefer"
    + " panic=15 clk_ignore_unused pd_ignore_unused"
    + " androidboot.bootdevice=1d84000.ufshc"
    + " msm_drm.dsi_display0=qcom,mdss_dsi_zhiyu_nt36526_csot_dsc_vid:"
    + " hqsysfs.pcba_stage=PVT ufsffu.boot_mode=normal rootwait ro"
    + " init=/sbin/init silent_boot.mode=nonsilent no_console_suspend"
    + " pm_debug_messages mem_sleep_default=s2idle";

  baseCmdline = lib.concatStringsSep " " (lib.filter (s: s != "") ([ boardCmdline ] ++ kernelParams));

  # Two independent IDs, both derived from serialized build inputs (never from
  # the finished images or the generation, which would be circular):
  #   kernel_id  -> boot.img command line
  #   vendor_id  -> vendor_bootconfig
  # The generation stores both in etc/zhiyu/boot-id, so a boot can verify that
  # the images on the flash are the ones that generation was built for.
  artifactId =
    inputs: builtins.hashString "sha256" (builtins.unsafeDiscardStringContext (builtins.toJSON inputs));
  commonIdInputs = {
    format = "zhiyu-avb-v2-ids";
    tool = android-tools.drvPath;
    key = builtins.hashFile "sha256" avbKey;
    inherit
      pagesize
      osVersion
      osPatch
      salt
      ;
  };
  kernelId = artifactId (
    commonIdInputs
    // {
      kernel = kernel.drvPath;
      cmdline = baseCmdline;
      size = partitions.boot;
    }
  );
  vendorId = artifactId (
    commonIdInputs
    // {
      dtb = dtb.drvPath;
      ramdisk = initramfs.drvPath;
      inherit bootconfig;
      size = partitions.vendor_boot;
    }
  );
  bootId = "${kernelId} ${vendorId}";
  cmdline = baseCmdline + " zhiyu.kernel_id=${kernelId}";
  allBootconfig = [ "zhiyu.vendor_id=${vendorId}" ] ++ bootconfig;

  bootconfigFile = lib.optionalString (allBootconfig != [ ]) ''
    {
      printf '%s\n' '# Merged by the kernel into its command line; keys must start with "kernel.".'
      printf '%s\n' ${lib.escapeShellArgs allBootconfig}
    } > $work/bootconfig.extra
  '';
in
rec {
  inherit bootId kernelId vendorId;

  boot = stdenv.mkDerivation {
    pname = "zhiyu-boot";
    inherit (kernel) version;

    dontUnpack = true;
    nativeBuildInputs = [
      android-tools
      openssl
    ];

    buildCommand = ''
      mkdir -p $out work
      work=$PWD/work

      # avbtool re-opens "<dir>/<partition_name>.img" to verify the footer it
      # just wrote, so the image is built under the partition's name.
      img=$work/boot.img
      mkbootimg --header_version 4 --pagesize ${toString pagesize} \
        --kernel ${kernel}/Image \
        --cmdline ${lib.escapeShellArg cmdline} \
        --output "$img"

      avbtool add_hash_footer --image "$img" --partition_name boot \
        --partition_size ${toString partitions.boot} \
        --algorithm SHA256_RSA4096 --key ${avbKey} --salt ${salt} \
        --prop "com.android.build.boot.os_version:${osVersion}" \
        --prop "com.android.build.boot.security_patch:${osPatch}"
      avbtool verify_image --image "$img" --key ${avbKey}

      # header v4 keeps the command line in a fixed 1536-byte field.
      got=$(unpack_bootimg --boot_img "$img" 2>/dev/null | sed -n 's/^command line args: //p')
      [ "$got" = ${lib.escapeShellArg cmdline} ] || {
        echo "boot: command line did not survive the header" >&2
        exit 1
      }
      [ "$(unpack_bootimg --boot_img "$img" 2>/dev/null | sed -n 's/^kernel_size: //p')" \
        = "$(stat -c %s ${kernel}/Image)" ] || {
        echo "boot: kernel size mismatch" >&2
        exit 1
      }
      cp -f "$img" $out/boot.img
    '';
  };

  vendorBoot = stdenv.mkDerivation {
    pname = "zhiyu-vendor-boot";
    inherit (kernel) version;

    dontUnpack = true;
    nativeBuildInputs = [
      android-tools
      openssl
    ];

    buildCommand = ''
      mkdir -p $out work
      work=$PWD/work
      cp -f ${dtb}/lenovo-zhiyu.dtb $work/board.dtb
      ${bootconfigFile}

      img=$work/vendor_boot.img
      mkbootimg --header_version 4 --pagesize ${toString pagesize} \
        --vendor_ramdisk ${initramfs}/initramfs.cpio.zst \
        --dtb $work/board.dtb \
        ${lib.optionalString (allBootconfig != [ ]) "--vendor_bootconfig $work/bootconfig.extra"} \
        --vendor_boot "$img"

      avbtool add_hash_footer --image "$img" --partition_name vendor_boot \
        --partition_size ${toString partitions.vendor_boot} \
        --algorithm SHA256_RSA4096 --key ${avbKey} --salt ${salt} \
        --prop "com.android.build.vendor_boot.os_version:${osVersion}" \
        --prop "com.android.build.vendor_boot.security_patch:${osPatch}"
      avbtool verify_image --image "$img" --key ${avbKey}

      unpack=$(unpack_bootimg --boot_img "$img" 2>/dev/null)
      [ "$(echo "$unpack" | sed -n 's/^vendor ramdisk total size: //p')" \
        = "$(stat -c %s ${initramfs}/initramfs.cpio.zst)" ] || {
        echo "vendor_boot: ramdisk size mismatch" >&2
        exit 1
      }
      [ "$(echo "$unpack" | sed -n 's/^dtb size: //p')" \
        = "$(stat -c %s ${dtb}/lenovo-zhiyu.dtb)" ] || {
        echo "vendor_boot: dtb size mismatch" >&2
        exit 1
      }
      cp -f "$img" $out/vendor_boot.img
    '';
  };

  # Empty generic ramdisk: /init and the boot-time modules live in
  # vendor_boot.  It depends on neither the kernel nor the ramdisk, so it has
  # its own version and is built once and then reused.
  initBoot = stdenv.mkDerivation {
    pname = "zhiyu-init-boot";
    version = "1";

    dontUnpack = true;
    nativeBuildInputs = [
      android-tools
      cpio
      openssl
      zstd
    ];

    buildCommand = ''
      mkdir -p $out work
      work=$PWD/work
      mkdir -p $work/empty
      # cpio stores mtimes; without this the empty ramdisk changes every build.
      touch -h -d @''${SOURCE_DATE_EPOCH:-0} $work/empty
      ( cd $work/empty && find . -print0 | sort -z \
          | cpio --null -o --format=newc --owner=0:0 --reproducible --quiet \
          | zstd -19 -T0 --no-progress ) > $work/empty.cpio.zst

      img=$work/init_boot.img
      mkbootimg --header_version 4 --pagesize ${toString pagesize} \
        --ramdisk $work/empty.cpio.zst --output "$img"

      avbtool add_hash_footer --image "$img" --partition_name init_boot \
        --partition_size ${toString partitions.init_boot} \
        --algorithm SHA256_RSA4096 --key ${avbKey} --salt ${salt} \
        --prop "com.android.build.init_boot.os_version:${osVersion}" \
        --prop "com.android.build.init_boot.security_patch:${osPatch}"
      avbtool verify_image --image "$img" --key ${avbKey}
      cp -f "$img" $out/init_boot.img
    '';
  };

  vbmeta = stdenv.mkDerivation {
    pname = "zhiyu-vbmeta";
    inherit (kernel) version;

    dontUnpack = true;
    nativeBuildInputs = [
      android-tools
      openssl
    ];

    buildCommand = ''
      mkdir -p $out work
      work=$PWD/work
      # avbtool looks the referenced partitions up next to the vbmeta output,
      # so give it the three images under their partition names.
      ln -s ${boot}/boot.img "$work/boot.img"
      ln -s ${vendorBoot}/vendor_boot.img "$work/vendor_boot.img"
      ln -s ${initBoot}/init_boot.img "$work/init_boot.img"

      avbtool make_vbmeta_image --output "$work/vbmeta.img" \
        --algorithm SHA256_RSA4096 --key ${avbKey} --padding_size 65536 \
        --flags 3 \
        --include_descriptors_from_image "$work/boot.img" \
        --include_descriptors_from_image "$work/vendor_boot.img" \
        --include_descriptors_from_image "$work/init_boot.img"
      avbtool verify_image --image "$work/vbmeta.img" --key ${avbKey}
      cp -f "$work/vbmeta.img" $out/vbmeta.img
    '';
  };

  # The directory the update/flash tools expect: the four images (symlinked,
  # so the store does not keep a second copy), SHA256SUMS and SIZES.  NixOS
  # does not need the compressed variants: the flasher reads the plain images
  # and the store already compresses NARs.
  bundle = stdenv.mkDerivation {
    pname = "zhiyu-images";
    inherit (kernel) version;

    dontUnpack = true;

    buildCommand = ''
      mkdir -p $out
      ln -s ${boot}/boot.img $out/boot.img
      ln -s ${vendorBoot}/vendor_boot.img $out/vendor_boot.img
      ln -s ${initBoot}/init_boot.img $out/init_boot.img
      ln -s ${vbmeta}/vbmeta.img $out/vbmeta.img

      ( cd $out && sha256sum *.img | sort -k2 > SHA256SUMS )
      ( cd $out && for img in *.img; do
          printf '%s %s\n' "$(stat -L -c %s "$img")" "$img"
        done | sort -k2 > SIZES )

      printf '%s\n' ${lib.escapeShellArg bootId} > $out/BOOT-IDS

      cat $out/SHA256SUMS
    '';
  };
}
