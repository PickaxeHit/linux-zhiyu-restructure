# sensh: the SNS (sensor) QMI client that sensord drives.  Not in nixpkgs, but
# its build-time tools (qmic, protobuf-c, libqrtr) are.  Everything is a native
# aarch64 build, so the qmic IDL compiler (aarch64-only in nixpkgs) is always
# used; meson generates qmi_sns_client.c/h from sns_client.qmi.
{
  lib,
  stdenv,
  fetchgit,
  sources,
  meson,
  ninja,
  pkg-config,
  protobufc,
  qrtr,
  qmic,
}:

stdenv.mkDerivation {
  pname = "sensh";
  version = "2.1.1-unstable-2025-01-06";

  src = fetchgit {
    inherit (sources.sensh) url rev hash;
  };

  nativeBuildInputs = [
    meson
    ninja
    pkg-config
    protobufc
    qmic
  ];

  buildInputs = [
    protobufc
    qrtr
  ];

  meta = {
    description = "Qualcomm SNS sensor client for the ADSP";
    platforms = lib.platforms.linux;
    mainProgram = "sensh";
  };
}
