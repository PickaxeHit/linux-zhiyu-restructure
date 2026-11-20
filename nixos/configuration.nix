# A complete NixOS system for the Lenovo TB378FC ("zhiyu").
#
# Build it from this repository, on the board itself (or any aarch64 builder):
#
#   nix build .#nixosConfigurations.zhiyu.config.system.build.toplevel
#   nix build .#nixosConfigurations.zhiyu.config.system.build.zhiyuImages
#
# Only two things are board specific here: the imported module (kernel,
# ramdisk, firmware, udev, sensord, images) and the libcamera source override
# below.  Everything else is an ordinary NixOS configuration.
{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [ ../nix/nixos-module.nix ];

  nixpkgs.config.allowUnfree = true;

  system.stateVersion = "26.05";
  time.timeZone = "Asia/Shanghai";
  i18n.supportedLocales = [
    "zh_CN.UTF-8/UTF-8"
    "zh_TW.UTF-8/UTF-8"
    "en_US.UTF-8/UTF-8"
  ];

  # ---- boot ------------------------------------------------------------
  # The vendor ramdisk does the real work: it unlocks the metadata-encrypted
  # userdata, mounts /data/linux (or the ext4 fallback on the SD card) and
  # switch_roots here.  "none"/"auto" with noCheck keeps NixOS from mounting
  # or fscking a device that is already mounted and must not be touched; the
  # real root is whatever the ramdisk chose.
  fileSystems."/" = {
    device = "none";
    fsType = "auto";
    noCheck = true;
  };

  zhiyu.enable = true;

  # Kernel parameters are baked into boot.img (there is no bootloader entry to
  # edit), including the LSM set this system runs:
  # NixOS turns boot.consoleLogLevel into `loglevel=`; putting loglevel in
  # boot.kernelParams as well would just be overridden by it.
  boot.consoleLogLevel = 7;
  boot.kernelParams = [ "ignore_loglevel" ];
  # zhiyu.bootconfig = [ "kernel.foo=1" ];   # vendor_bootconfig

  # ---- networking ------------------------------------------------------
  networking.hostName = "nixos-pad";
  networking.networkmanager.enable = true;
  networking.firewall.enable = true;

  # ---- users -----------------------------------------------------------
  # Set a password with `passwd` after the first boot; no default password is
  # shipped, and SSH password login stays available for that first login.
  users.users.pickaxehit = {
    isNormalUser = true;
    # No password is shipped: set one at installation time (passwd) or log in
    # with an SSH key.  CI no longer substitutes a known default here.
    extraGroups = [
      "wheel"
      "networkmanager"
      "video"
      "audio"
      "render"
    ];
  };
  services.openssh.enable = true;

  # ---- desktop ---------------------------------------------------------
  services.xserver.enable = true;
  services.xserver.xkb.layout = "us";
  services.displayManager.plasma-login-manager.enable = true;
  services.desktopManager.plasma6.enable = true;
  hardware.graphics.enable = true;
  services.libinput.enable = true;

  # ---- audio -----------------------------------------------------------
  services.pipewire.enable = true;
  services.pipewire.alsa.enable = true;
  services.pipewire.pulse.enable = true;
  security.rtkit.enable = true;

  # ---- bluetooth -------------------------------------------------------
  hardware.bluetooth.enable = true;
  hardware.bluetooth.powerOnBoot = true;

  # ---- security --------------------------------------------------------
  # The kernel has SELinux and AppArmor built in.  NixOS's security.lsm (fed by
  # this option) is what ends up in boot.kernelParams and therefore in the
  # flashed boot.img.
  security.apparmor.enable = true;

  # ---- hardware tools --------------------------------------------------
  # libcamera-zhiyu gives `cam`; the rest are for checking the video, Vulkan,
  # OpenCL, V4L2 and audio paths on the device.
  environment.systemPackages = with pkgs; [
    libva-utils
    vulkan-tools
    clinfo
    v4l-utils
    alsa-utils
    qrtr
  ];

  # ---- fonts -----------------------------------------------------------
  fonts.packages = with pkgs; [
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-cjk-serif
    noto-fonts-color-emoji
  ];
}
