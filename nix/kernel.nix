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
  sources,
  ...
}@args:

let
  src = fetchFromGitHub {
    inherit (sources.kernel)
      owner
      repo
      rev
      hash
      ;
  };

  forwarded = builtins.removeAttrs args [
    "lib"
    "linuxManualConfig"
    "fetchFromGitHub"
    "sources"
  ];

  configFile = ../configs/linux-7.3-zhiyu.config;
in
(linuxManualConfig (
  forwarded
  // {
    pname = "linux-zhiyu";
    inherit (sources.kernel) version modDirVersion;
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
