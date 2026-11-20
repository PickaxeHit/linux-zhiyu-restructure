# sensh: the SNS (sensor) QMI client that sensord drives.  Not in nixpkgs, but
# its build-time tools (qmic, protobuf-c, libqrtr) are.  Everything is a native
# aarch64 build, so the qmic IDL compiler (aarch64-only in nixpkgs) is always
# used; meson generates qmi_sns_client.c/h from sns_client.qmi.
{
  lib,
  stdenv,
  fetchgit,
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
    url = "https://gitlab.com/flamingradian/sensh.git";
    rev = "560b48080283fe73ca5e67635b566177028cebc9";
    hash = "sha256-sh/0BoGpBXF+GzLstQ8mObsCtDcnccm7yT0xArijn+g=";
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
