# The udev rules the Debian/Arch packages install (scripts/*.rules): stable
# /dev/video* names, dma-heap/fastrpc permissions and the flash LED.
{
  lib,
  stdenv,
  coreutils,
}:

let
  rules = [
    "60-persistent-v4l.rules"
    "90-dma-heap.rules"
    "90-fastrpc.rules"
    "91-flash-led.rules"
  ];
in
stdenv.mkDerivation {
  pname = "zhiyu-udev-rules";
  version = "unstable";

  dontUnpack = true;

  installPhase = ''
    for rule in ${toString rules}; do
      install -Dm0644 ${../scripts}/"$rule" "$out/lib/udev/rules.d/$rule"
    done
    # The rule file is shared with the distro packages, where /bin/chmod
    # exists; NixOS has no /bin, so point it at coreutils.
    substituteInPlace $out/lib/udev/rules.d/91-flash-led.rules \
      --replace-fail /bin/chmod ${coreutils}/bin/chmod
  '';

  meta = {
    description = "udev rules for the Lenovo TB378FC";
    platforms = lib.platforms.linux;
  };
}
