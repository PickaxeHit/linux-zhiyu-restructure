# sensors/sensord.c: SensorProxy daemon backed by the ADSP sensor PD.
# The Makefile is a plain pkg-config build; on a native build pkg-config's
# wrapper handles glib/gio as usual, so no flags need to be passed by hand.
{
  lib,
  stdenv,
  pkg-config,
  glib,
  sensh,
  systemd,
}:

stdenv.mkDerivation {
  pname = "zhiyu-sensord";
  version = "unstable";
  src = builtins.path {
    path = ../sensors;
    name = "zhiyu-sensord-src";
    filter =
      path: type:
      builtins.elem (baseNameOf path) [
        "Makefile"
        "sensord.c"
      ];
  };

  strictDeps = true;

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [
    glib
    sensh
  ];

  # The daemon spawns sensh and systemd-notify; both upstream paths are
  # traditional-distro paths that do not exist on NixOS.
  postPatch = ''
    substituteInPlace sensord.c \
      --replace-fail '/usr/local/bin/sensh' '${sensh}/bin/sensh' \
      --replace-fail '/usr/bin/systemd-notify' '${systemd}/bin/systemd-notify'
  '';

  installPhase = ''
    runHook preInstall
    install -Dm0755 sensord $out/bin/zhiyu-sensord
    runHook postInstall
  '';

  meta = {
    description = "SensorProxy daemon for the Lenovo TB378FC";
    platforms = lib.platforms.linux;
  };
}
