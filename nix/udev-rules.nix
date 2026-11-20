# The udev rules the Debian/Arch packages install: stable /dev/video* names,
# dma-heap/fastrpc permissions and the flash LED.  The files are referenced
# one by one so unrelated files in scripts/ do not change the derivation.
{
  lib,
  stdenv,
  coreutils,
}:

let
  rules = [
    ../scripts/60-persistent-v4l.rules
    ../scripts/90-dma-heap.rules
    ../scripts/90-fastrpc.rules
    ../scripts/91-flash-led.rules
  ];
in
stdenv.mkDerivation {
  pname = "zhiyu-udev-rules";
  version = "unstable";

  dontUnpack = true;

  installPhase = ''
    ${lib.concatMapStringsSep "\n" (rule: ''
      install -Dm0644 ${rule} \
        "$out/lib/udev/rules.d/${baseNameOf (toString rule)}"
    '') rules}
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
