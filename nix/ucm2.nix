# ALSA UCM2 tree for the SM8750 sound card: the stock tree plus the board's
# configuration.  Exported through ALSA_CONFIG_UCM2 (and /etc/alsa/ucm2) by the
# NixOS module; alsa-lib does not search /etc by itself.
{
  lib,
  runCommand,
  alsa-ucm-conf,
}:

runCommand "zhiyu-ucm2" { } ''
  mkdir -p $out
  cp -a ${alsa-ucm-conf}/share/alsa/ucm2/. $out/
  # cp -a copies the store directory's read-only mode onto $out as well.
  chmod -R u+w $out
  mkdir -p $out/conf.d/sm8750 $out/sm8750
  cp -a ${../scripts/alsa-ucm2}/conf.d/sm8750/. $out/conf.d/sm8750/
  cp ${../scripts/alsa-ucm2}/sm8750/HiFi.conf $out/sm8750/HiFi.conf
''
