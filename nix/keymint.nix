# The static KeyMint/QCOMTEE clients that the initramfs runs before the
# rootfs exists: keymint-recover (unlock_metadata.c), keymint-rpmb
# (rpmb_proxy.c) and keymint-time (time_main.c).  userdata-map comes straight
# from initramfs-src/src/userdata-map.c.
#
# Same stack as keymint/build-deps.sh (QCBOR, quic-teec, minkipc, idlc), but
# every piece is a derivation: idlc runs during the build, the libraries are
# compiled for the board, and libcrypto comes from the nixpkgs OpenSSL built
# with `static = true` instead of the pinned Ubuntu libssl-dev package.
{
  lib,
  stdenv,
  fetchFromGitHub,
  rustPlatform,
  git,
  cmake,
  ninja,
  pkg-config,
  openssl,
}:

let
  qcborSrc = fetchFromGitHub {
    owner = "laurencelundblade";
    repo = "QCBOR";
    rev = "572a567d02bcfde42f5863f6a515131cc270798d";
    hash = "sha256-pP61a2/FAlb9TJfCBkdW57o5mhnF2/mKdXnribJoFzo=";
  };

  teecSrc = fetchFromGitHub {
    owner = "quic";
    repo = "quic-teec";
    rev = "736419e25a2036aac3292a10a93e394a90750ca3";
    hash = "sha256-HVtw2RT3LxwcRifzX9XT7nNsWPCJesVbuAhjPSgscus=";
  };

  minkSrc = fetchFromGitHub {
    owner = "quic";
    repo = "minkipc";
    rev = "5e3c6951d13162a262ea65ea8e8351228f092b58";
    hash = "sha256-52vUyTz9rLG/qmLrkS4IO+AMVbXqsBQa5RcVRy0RuQs=";
  };

  idlcSrc = fetchFromGitHub {
    owner = "quic";
    repo = "mink-idl-compiler";
    rev = "95ebb8d6031dd2c8d3f6277e50edadee8a119d5b";
    hash = "sha256-zKQUF2FeKDkX5jymiAZ220WmvwK6Yv3qfzBa/ionySQ=";
  };

  # idlc is a code generator: it must run on the *build* machine.
  idlc = rustPlatform.buildRustPackage {
    pname = "mink-idlc";
    version = "0.2.0";
    src = idlcSrc;
    # Upstream tarballs carry no lock file; the repository pins one.
    cargoDeps = rustPlatform.importCargoLock {
      lockFile = ../keymint/idlc.Cargo.lock;
    };
    postUnpack = ''
      cp ${../keymint/idlc.Cargo.lock} $sourceRoot/Cargo.lock
    '';
    cargoBuildFlags = [
      "-p"
      "idlc"
    ];
    doCheck = false;
    # idlc's build.rs shells out to `git describe` for the version string.
    nativeBuildInputs = [ git ];
    installPhase = ''
      runHook preInstall
      name=$(find . -maxdepth 5 -type f -name idlc -perm -u+x | head -1)
      test -n "$name" || { echo "idlc binary not found; target dirs:" >&2; find . -maxdepth 3 -type d -name target >&2; exit 1; }
      install -Dm0755 "$name" $out/bin/idlc
      runHook postInstall
    '';
  };

  qcbor = stdenv.mkDerivation {
    pname = "qcbor-zhiyu";
    version = "unstable";
    src = qcborSrc;
    nativeBuildInputs = [ cmake ];
    cmakeFlags = [
      "-DCMAKE_INSTALL_INCLUDEDIR=include"
      "-DCMAKE_INSTALL_LIBDIR=lib"
      "-DCMAKE_INSTALL_BINDIR=bin"
      "-DBUILD_SHARED_LIBS=OFF"
      "-DCMAKE_POSITION_INDEPENDENT_CODE=ON"
      "-DQCBOR_BUILD_TESTS=OFF"
      "-DQCBOR_BUILD_EXAMPLES=OFF"
    ];
  };

  teec = stdenv.mkDerivation {
    pname = "quic-teec-zhiyu";
    version = "unstable";
    src = teecSrc;
    nativeBuildInputs = [
      cmake
      pkg-config
    ];
    cmakeFlags = [
      "-DCMAKE_INSTALL_INCLUDEDIR=include"
      "-DCMAKE_INSTALL_LIBDIR=lib"
      "-DCMAKE_INSTALL_BINDIR=bin"
      "-DQCBOR_DIR_HINT=${qcbor}"
      "-DBUILD_SHARED_LIBS=OFF"
      "-DCMAKE_POSITION_INDEPENDENT_CODE=ON"
    ];
  };

  # Upstream builds libminkadaptor as a shared library only, and generates the
  # CBO IDL headers with idlc in the middle of the cmake build.  Both are
  # simpler here: idlc is run for each .idl, and the three sources are
  # archived statically.  Doing it this way also keeps the headers next to the
  # library, which is what the clients below need.
  mink = stdenv.mkDerivation {
    pname = "libminkadaptor-zhiyu";
    version = "unstable";
    src = minkSrc;
    nativeBuildInputs = [ idlc ];
    hardeningDisable = [ "all" ];

    buildPhase = ''
      runHook preBuild
      for idl in listeners/listenercbo/idl/*.idl; do
        idlc "$idl" -o "''${idl%.idl}.h"
        idlc "$idl" -o "''${idl%.idl}_invoke.h" --skel
      done
      $CC -c -O2 -D_GNU_SOURCE \
        -Ilibminkadaptor/include -Ilibminkadaptor/src \
        -Ilisteners/listenercbo/include \
        -I${teec}/include -I${qcbor}/include \
        libminkadaptor/src/mink_adaptor.c \
        libminkadaptor/src/supplicant.c \
        libminkadaptor/src/syscall.S
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/include $out/lib
      cp libminkadaptor/include/*.h $out/include/
      cp listeners/listenercbo/include/*.h $out/include/
      cp listeners/listenercbo/src/memscpy.h $out/include/
      cp listeners/libtimeservice/time_msg.h $out/include/
      cp listeners/listenercbo/idl/*.h $out/include/
      $AR rcs $out/lib/libminkadaptor.a *.o
      runHook postInstall
    '';
  };

  # Static OpenSSL: nixpkgs' default build installs only the shared libraries.
  opensslStatic = openssl.override { static = true; };
in
stdenv.mkDerivation {
  pname = "zhiyu-keymint-tools";
  version = "unstable";

  dontUnpack = true;
  nativeBuildInputs = [ ];
  buildInputs = [ stdenv.cc.libc.static ];

  buildCommand = ''
    mkdir -p $out/bin
    flags="-O2 -Wall -Wextra -pthread -static -ffunction-sections -fdata-sections -Wl,--gc-sections"
    inc="-I${mink}/include -I${opensslStatic.dev}/include"
    libs="${mink}/lib/libminkadaptor.a ${teec}/lib/libqcomtee.a ${qcbor}/lib/libqcbor.a \
      ${opensslStatic.out}/lib/libcrypto.a -lpthread -ldl -lrt"

    # Recover the existing Android metadata key through the TEE KeyMint TA.
    $CC $flags $inc -Wno-deprecated-declarations \
      ${../keymint/unlock_metadata.c} $libs -o $out/bin/keymint-recover

    # RPMB proxy: the TA talks RPMB through this instead of the kernel.
    $CC $flags $inc \
      ${../keymint/rpmb_proxy.c} ${minkSrc}/listeners/listenercbo/src/CListenerCBO.c \
      $libs -o $out/bin/keymint-rpmb

    # Time listener: keeps the TA's clock in sync after resume.
    $CC $flags $inc \
      ${../keymint/time_main.c} ${minkSrc}/listeners/libtimeservice/atime.c \
      ${minkSrc}/listeners/listenercbo/src/CListenerCBO.c \
      $libs -o $out/bin/keymint-time

    for tool in $out/bin/*; do
      file -b "$tool" | grep -q "statically linked" \
        || { echo "$tool is not statically linked" >&2; exit 1; }
    done
  '';

  meta = {
    description = "Static KeyMint/QCOMTEE clients for the Lenovo TB378FC";
    platforms = lib.platforms.linux;
  };
}
