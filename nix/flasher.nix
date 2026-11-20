# zhiyu-install: the boot-image flasher used as NixOS's installBootLoader
# (boot.loader.external).  It writes the images that belong to the generation
# being installed, only into the running slot, and only the partitions whose
# content actually changed.
{
  lib,
  stdenv,
  openssl,
}:

stdenv.mkDerivation {
  pname = "zhiyu-install";
  version = "1";

  dontUnpack = true;

  buildInputs = [ openssl ];

  buildPhase = ''
    runHook preBuild
    $CC -O2 -Wall -Wextra -Werror -o zhiyu-install ${./flasher.c} -lcrypto
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm0755 zhiyu-install $out/bin/zhiyu-install
    runHook postInstall
  '';

  meta = {
    description = "AVB boot-image flasher for the Lenovo TB378FC";
    platforms = lib.platforms.linux;
  };
}
