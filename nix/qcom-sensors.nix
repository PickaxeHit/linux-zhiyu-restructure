# SNS configuration and registry that hexagonrpcd serves to the ADSP.  The
# repository keeps them next to the firmware blobs; CI installs the same files
# under /usr/share/qcom in the distro rootfs packages.
{
  lib,
  stdenv,
}:

stdenv.mkDerivation {
  pname = "qcom-sensors";
  version = "1";

  dontUnpack = true;

  installPhase = ''
    install -d $out/share/qcom/sensors
    cp -a ${../initramfs-src/blobs/sensors}/. $out/share/qcom/sensors/
  '';

  meta = {
    description = "SNS config and registry for the SM8750 ADSP";
    platforms = lib.platforms.linux;
  };
}
