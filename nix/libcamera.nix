# The libcamera fork at the 0.7.2 release branch.  The source comes from
# metadata/sources.lock.json, so the flake and the NixOS module use exactly
# the same tarball as the submodule gitlink.
{
  libcamera,
  fetchFromGitHub,
  sources,
}:

libcamera.overrideAttrs (_: {
  src = fetchFromGitHub {
    inherit (sources."libcamera-0.7")
      owner
      repo
      rev
      hash
      ;
  };
})
