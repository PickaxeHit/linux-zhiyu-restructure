# VA-API backend for Qualcomm Iris (V4L2 M2M stateful decoder/encoder).  Mesa's
# Freedreno/Turnip do not provide this; it is a separate libva driver that the
# kernel's qcom Venus/Iris V4L2 nodes are used through.
#
# Same configuration the Arch package uses: GPU surface copy, no CDSP/Vulkan
# video post-processing (those need the proprietary ghc/Vulkan skeletons and
# are not used for VA-API).
{
  lib,
  stdenv,
  fetchFromGitHub,
  sources,
  meson,
  ninja,
  pkg-config,
  libva,
  libdrm,
  libglvnd,
  libgbm,
}:

stdenv.mkDerivation {
  pname = "qcom-va-driver";
  version = "1.1.1";

  src = fetchFromGitHub {
    inherit (sources.qcom-va-driver)
      owner
      repo
      rev
      hash
      ;
  };

  nativeBuildInputs = [
    meson
    ninja
    pkg-config
  ];
  buildInputs = [
    libva
    libdrm
    libglvnd
    libgbm
  ];

  mesonFlags = [
    # Not "auto": a missing EGL/GLES/GBM must fail the build instead of
    # silently falling back to the slow CPU surface copy.
    "-Dgpu_copy=enabled"
    "-Dcdsp_vpp=disabled"
    "-Dvulkan_vpp=disabled"
  ];

  meta = {
    description = "VA-API driver for Qualcomm Iris video hardware";
    homepage = "https://github.com/radxa-pkg/qcom-va-driver";
    license = lib.licenses.mit;
    platforms = lib.platforms.aarch64;
  };
}
