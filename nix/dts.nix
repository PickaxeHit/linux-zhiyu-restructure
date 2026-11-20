# The board device tree.  It lives outside the kernel tree and only needs the
# kernel headers for its <dt-bindings/...> includes, exactly like
# mkvendorbootimg's `cpp -nostdinc -I $KS/include -undef` step.
{
  lib,
  stdenv,
  dtc,
  kernel,
  dts,
}:

stdenv.mkDerivation {
  pname = "lenovo-zhiyu-dtb";
  version = kernel.version;

  nativeBuildInputs = [ dtc ];

  buildCommand = ''
    mkdir -p $out
    cpp -nostdinc -I ${kernel.src}/include -undef \
      -x assembler-with-cpp -o board.dts ${dts}
    dtc -I dts -O dtb -o $out/lenovo-zhiyu.dtb board.dts
    cp ${dts} $out/lenovo-zhiyu.dts
  '';

  meta = {
    description = "Device tree blob for the Lenovo TB378FC";
    platforms = lib.platforms.linux;
  };
}
