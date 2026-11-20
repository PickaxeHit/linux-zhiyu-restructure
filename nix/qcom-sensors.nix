# SNS configuration and registry that hexagonrpcd serves to the ADSP.  They
# come from the same firmware-blobs archive as the firmware, so the
# lightweight nix-stable branch does not need the blobs in the tree.
{
  lib,
  stdenv,
  fetchzip,
  sources,
}:

let
  firmwareBlobs = fetchzip {
    inherit (sources.firmware-blobs) url hash;
    # The archive has two top-level directories (firmware, sensors).
    stripRoot = false;
  };
in
stdenv.mkDerivation {
  pname = "qcom-sensors";
  version = "1";

  dontUnpack = true;

  installPhase = ''
    install -d $out/share/qcom/sensors
    cp -a ${firmwareBlobs}/sensors/. $out/share/qcom/sensors/
  '';

  meta = {
    description = "SNS config and registry for the SM8750 ADSP";
    platforms = lib.platforms.linux;
  };
}
