# Everything that ends up in /lib/firmware: the vendor blobs plus the SM8750
# audio topology, which is *built* (m4 + alsatplg) rather than shipped as a
# blob.  Shared by the initramfs (needed before switch_root, see
# initramfs-src/fs/init) and by the rootfs (`hardware.firmware` in the NixOS
# module): after switch_root the ramdisk's copy is gone, and drivers that probe
# late (GPU, bluetooth, touch, codec) ask the rootfs for their firmware.
{
  lib,
  stdenv,
  fetchFromGitHub,
  sources,
  m4,
  alsa-utils,
}:

let
  # The blobs live in PickaxeHit/linux-zhiyu-firmware at the commit recorded in
  # metadata/sources.lock.json.
  firmwareBlobs = fetchFromGitHub {
    inherit (sources.firmware)
      owner
      repo
      rev
      hash
      ;
  };

  # The topology's entry point includes the vendor tree ("audioreach/...",
  # "util/..."), pinned in metadata/sources.lock.json.
  audioreach = fetchFromGitHub {
    inherit (sources.audioreach)
      owner
      repo
      rev
      hash
      ;
  };
in
stdenv.mkDerivation {
  pname = "zhiyu-firmware";
  version = "unstable";

  dontUnpack = true;

  nativeBuildInputs = [
    m4
    alsa-utils
  ];

  buildCommand = ''
    mkdir -p $out/lib/firmware
    cp -a ${firmwareBlobs}/firmware/. $out/lib/firmware/
    # cp -a copies the store's read-only mode along with the files, and
    # alsatplg writes the topology into this tree below.
    chmod -R u+w $out/lib/firmware

    # ---- SM8750 audio topology ------------------------------------------
    # Zhiyu-vendorprops.m4 includes piano/*.m4 from its own directory and
    # audioreach/*, util/* from the pinned vendor tree.
    mkdir -p tplg
    cp ${../initramfs-src/tplg/Zhiyu-vendorprops.m4} tplg/
    cp -r ${../initramfs-src/tplg/piano} tplg/piano
    ( cd tplg && m4 -I . -I ${audioreach} Zhiyu-vendorprops.m4 > ../sm8750-tplg.conf )
    mkdir -p $out/lib/firmware/qcom/sm8750
    alsatplg -c sm8750-tplg.conf -o $out/lib/firmware/qcom/sm8750/sm8750-tplg.bin
    test "$(head -c 4 $out/lib/firmware/qcom/sm8750/sm8750-tplg.bin)" = CoSA
  '';

  meta = {
    description = "Firmware and audio topology for the Lenovo TB378FC";
    platforms = lib.platforms.linux;
  };
}
