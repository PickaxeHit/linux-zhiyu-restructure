# The kernel we boot: mainline, plus the zhiyu branch that carries the board
# support.  Same source the README's build.sh uses (the kernel-source
# submodule), pinned to a revision so the build does not need a git checkout.
#
# NixOS applies its own overlay to boot.kernelPackages.kernel and calls
# .override with `features`/`randstructSeed`, so anything it (or a user) passes
# is forwarded to linuxManualConfig instead of being rejected.
{
  lib,
  linuxManualConfig,
  fetchFromGitHub,
  ...
}@args:

let
  src = fetchFromGitHub {
    owner = "PickaxeHit";
    repo = "linux-kernel-zhiyu";
    rev = "c43439cdf54f03154a283aa1af06fe5cd55598a3";
    hash = "sha256-XuL5Jl9OmfHGxo3NZYVm2ypMT22wInRCdbH8TCQwYOE=";
  };

  forwarded = builtins.removeAttrs args [
    "lib"
    "linuxManualConfig"
    "fetchFromGitHub"
  ];

  configFile = ../configs/linux-7.3-zhiyu.config;
in
(linuxManualConfig (
  forwarded
  // {
    pname = "linux-zhiyu";
    version = "7.3.1";
    # CONFIG_LOCALVERSION="-zhiyu" in the config, so this is `make kernelrelease`.
    modDirVersion = "7.3.1-zhiyu";
    inherit src;

    configfile = configFile;
    # The board DTB is not in the kernel tree; nix/dts.nix builds it.
    buildDTBs = false;

    extraMeta = {
      branch = "zhiyu";
      platforms = lib.platforms.aarch64;
    };
  }
)).overrideAttrs
  (old: {
    # kconfig's oldconfig only *adds* defaults for symbols the config file does
    # not know about; it never fails.  A new nixpkgs (new GCC, new kernel
    # options) would therefore silently change the kernel.  Compare the result
    # with the file we ship and refuse to build on real drift.
    postConfigure = (old.postConfigure or "") + ''
      if ! diff -u \
          -I '^CONFIG_CC_' \
          -I '^CONFIG_GCC_VERSION' \
          -I '^CONFIG_AS_VERSION' \
          -I '^CONFIG_LD_VERSION' \
          -I '^CONFIG_RUSTC_' \
          -I '^CONFIG_PAHOLE_VERSION' \
          ${configFile} $buildRoot/.config > config-drift.diff; then
        echo "linux-zhiyu: the kernel config drifted from ${configFile}:" >&2
        head -120 config-drift.diff >&2
        echo "linux-zhiyu: update configs/ if the drift is intended" >&2
        exit 1
      fi
    '';
  })
