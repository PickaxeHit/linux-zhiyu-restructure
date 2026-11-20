# NixOS module for the Lenovo TB378FC (zhiyu).
#
# It does not replace the boot chain: the board has no ESP, no extlinux config
# and no NixOS bootloader — ABL loads `boot_<slot>` with a command line that is
# baked into boot.img.  What this module does is make NixOS build the *same*
# kernel, ramdisk and firmware the flashed images carry, so `nixos-rebuild` and
# the images stop drifting apart:
#
#   boot.kernelPackages        -> our kernel (modules version == `uname -r`)
#   boot.initrd.enable         -> off: the vendor ramdisk in vendor_boot is /init
#   hardware.firmware          -> blobs + built audio topology for late probes
#   system.build.zhiyuImages   -> boot/vendor_boot/init_boot/vbmeta, signed
#
# Usage (configuration.nix):
#
#   imports = [ (builtins.getFlake "git+file:///path/to/linux-zhiyu").nixosModules.default ];
#
#   zhiyu.enable = true;
#   boot.kernelParams = [ "loglevel=7" "lsm=landlock,yama,integrity,selinux" ];
#   zhiyu.bootconfig = [ "kernel.foo=1" ];                 # vendor_bootconfig
#
# then `nix build .#nixosConfigurations.<host>.config.system.build.zhiyuImages`
# and flash it with `zhiyu-install <system>` (see nix/flasher.c), or set
# zhiyu.flashOnSwitch to let NixOS call it during nixos-rebuild.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.zhiyu;

  # The board kernel is only the *default* for boot.kernelPackages; everything
  # below uses the kernel NixOS finally selected, so the ramdisk, the DTB and
  # boot.img can never describe a different build than the system itself.
  sources = lib.importJSON ../metadata/sources.lock.json;

  boardKernel = pkgs.callPackage ./kernel.nix { inherit sources; };
  kernel = config.boot.kernelPackages.kernel;

  keymint = pkgs.callPackage ./keymint.nix { inherit sources; };
  sensh = pkgs.callPackage ./sensh.nix { inherit sources; };
  sensord = pkgs.callPackage ./sensord.nix { inherit sensh; };

  firmware = pkgs.callPackage ./firmware.nix { inherit sources; };
  udevRules = pkgs.callPackage ./udev-rules.nix { };
  dbusPolicy = pkgs.callPackage ./sensord-dbus.nix { };
  qcomVaDriver = pkgs.callPackage ./qcom-va-driver.nix { inherit sources; };
  qcomSensors = pkgs.callPackage ./qcom-sensors.nix { inherit sources; };

  dtb = pkgs.callPackage ./dts.nix {
    inherit kernel;
    dts = ../dts/lenovo-zhiyu.dts;
  };

  initramfs = pkgs.callPackage ./initramfs.nix {
    inherit kernel keymint firmware;
  };

  # One image set, built from whatever boot.kernelPackages actually selects:
  # NixOS's own parameters (including lsm=) go straight into boot.img.
  ucm2 = pkgs.callPackage ./ucm2.nix { };

  # NixOS's security.lsm option (fed by security.apparmor.enable etc.) already
  # produces the right `lsm=` entry in boot.kernelParams; the board does not
  # second-guess it.  Duplicate keys such as console= are legitimate, so the
  # parameter list is passed through unchanged.
  kernelParams = config.boot.kernelParams;

  flasher = pkgs.callPackage ./flasher.nix { };

  images = pkgs.callPackage ./images.nix {
    inherit kernel dtb initramfs;
    inherit kernelParams;
    bootconfig = cfg.bootconfig;
  };
in
{
  options.zhiyu = {
    enable = lib.mkEnableOption "board support for the Lenovo TB378FC";

    flashOnSwitch = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Flash the generation's boot images into the running slot when NixOS
        installs the bootloader (nixos-rebuild boot/switch).  Off by default:
        the images are still put in <system>/etc/zhiyu/boot-images and kept by
        the generation, so `zhiyu-install <system>` can flash them explicitly.
      '';
    };

    bootconfig = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "kernel.panic=15" ];
      description = ''
        Entries written to vendor_bootconfig.  The kernel only merges keys that
        start with `kernel.` into its command line; other keys are visible to
        userspace through /proc/bootconfig.  The board's own parameters are
        already in the boot.img command line, so this is empty by default.
      '';
    };

    camera.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Install the zhiyu libcamera fork (simple pipeline, EGL debayer, CDAF)
        and redirect its stock libcamera consumers to it with
        system.replaceDependencies.
      '';
    };

    sensord.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Run sensors/sensord.c as zhiyu-sensord.  It talks to the ADSP through
        hexagonrpcd-adsp-sensorspd; the dependency is soft so a missing daemon
        cannot make the unit impossible to start.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    nixpkgs.overlays = lib.optional cfg.camera.enable (
      final: prev: {
        libcamera-zhiyu = prev.callPackage ./libcamera.nix {
          sources = sources;
        };
      }
    );
    system.replaceDependencies.replacements = lib.optional cfg.camera.enable {
      oldDependency = pkgs.libcamera;
      newDependency = pkgs.libcamera-zhiyu;
    };
    # The running kernel must be the one NixOS thinks it booted, otherwise
    # /run/booted-system/kernel-modules points at a different version and
    # udev/boot.kernelModules load nothing.
    boot.kernelPackages = lib.mkDefault (pkgs.linuxPackagesFor boardKernel);

    # /init comes from our ramdisk (vendor_boot); a NixOS stage-1 would be a
    # second /init in the same boot and could not unlock /data anyway.
    boot.initrd.enable = lib.mkForce false;

    # No ESP, no bootloader config: ABL only reads boot/vendor_boot/init_boot.
    boot.loader.grub.enable = lib.mkForce false;
    boot.loader.systemd-boot.enable = lib.mkForce false;
    boot.loader.generic-extlinux-compatible.enable = lib.mkForce false;

    # Late probes (GPU, bluetooth, touch, codec) ask the rootfs for firmware;
    # the ramdisk's copy is gone after switch_root.
    hardware.firmware = [ firmware ];

    services.udev.packages = [ udevRules ];

    # sensord publishes net.hadess.SensorProxy on the system bus.
    services.dbus.packages = [ dbusPolicy ];

    # hexagonrpcd is how the ADSP is reached (file service, sensors).  It runs
    # as the dedicated fastrpc user and needs /dev/fastrpc-adsp, which the
    # fastrpc module creates; 90-fastrpc.rules hands the device to that group.
    boot.kernelModules = [ "fastrpc" ];
    users.groups.fastrpc = { };
    users.users.fastrpc = {
      isSystemUser = true;
      group = "fastrpc";
      home = "/var/lib/fastrpc";
    };
    # hexagonrpcd serves a file tree to the ADSP and writes the sensor
    # registry into it, so the root has to be writable.  The read-only data
    # comes from the store, the registry directory is owned by fastrpc.
    # Read-only SNS data follows the generation; only the registry directory
    # stays writable, and it lives outside the generation so it survives
    # upgrades.
    systemd.tmpfiles.settings."10-zhiyu-sns" = {
      "/var/lib/qcom/sensors/registry".d = {
        mode = "0755";
        user = "fastrpc";
        group = "fastrpc";
      };
      "/var/lib/zhiyu-qcom/sensors".d.mode = "0755";
      "/var/lib/zhiyu-qcom/sensors/config"."L+".argument = "${qcomSensors}/share/qcom/sensors/config";
      "/var/lib/zhiyu-qcom/sensors/sns_reg.conf"."L+".argument =
        "${qcomSensors}/share/qcom/sensors/sns_reg.conf";
      "/var/lib/zhiyu-qcom/sensors/registry"."L+".argument = "/var/lib/qcom/sensors/registry";
    };

    systemd.services.hexagonrpcd-adsp-rootpd = {
      description = "Server for FastRPC remote procedure calls from Qualcomm ADSP - RootPD";
      wantedBy = [ "multi-user.target" ];
      conflicts = [ "suspend.target" ];
      before = [ "suspend.target" ];
      unitConfig.ConditionPathExists = [
        "!/dev/fastrpc-sdsp"
        "/dev/fastrpc-adsp"
      ];
      requires = [ "systemd-tmpfiles-setup.service" ];
      after = [ "systemd-tmpfiles-setup.service" ];
      restartTriggers = [ qcomSensors ];
      serviceConfig = {
        User = "fastrpc";
        Group = "fastrpc";
        ExecStart = "${pkgs.hexagonrpc}/bin/hexagonrpcd -f /dev/fastrpc-adsp -d adsp -R /var/lib/zhiyu-qcom";
        Restart = "always";
        RestartSec = 3;
      };
    };
    systemd.services.hexagonrpcd-adsp-sensorspd = {
      description = "Server for FastRPC remote procedure calls from Qualcomm ADSP - sensorspd";
      wantedBy = [ "multi-user.target" ];
      conflicts = [ "suspend.target" ];
      before = [ "suspend.target" ];
      unitConfig.ConditionPathExists = [
        "!/dev/fastrpc-sdsp"
        "/dev/fastrpc-adsp"
      ];
      requires = [ "systemd-tmpfiles-setup.service" ];
      after = [ "systemd-tmpfiles-setup.service" ];
      restartTriggers = [ qcomSensors ];
      serviceConfig = {
        User = "fastrpc";
        Group = "fastrpc";
        ExecStart = "${pkgs.hexagonrpc}/bin/hexagonrpcd -f /dev/fastrpc-adsp -d adsp -s -R /var/lib/zhiyu-qcom";
        Restart = "always";
        RestartSec = 3;
      };
    };

    # Mark the slot as successfully booted so ABL does not fall back to the
    # other slot after repeated attempts.  Separate from flasher (images) and
    # from NixOS generations (user space).
    systemd.services.zhiyu-boot-success = {
      description = "Mark the active slot as successfully booted";
      after = [
        "local-fs.target"
        "dev-disk-by\\x2dpartlabel-boot_a.device"
        "dev-disk-by\\x2dpartlabel-boot_b.device"
      ];
      wants = [
        "dev-disk-by\\x2dpartlabel-boot_a.device"
        "dev-disk-by\\x2dpartlabel-boot_b.device"
      ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.qbootctl}/bin/qbootctl -m";
      };
    };

    environment.etc."alsa/ucm2".source = ucm2;
    environment.sessionVariables.ALSA_CONFIG_UCM2 = "${ucm2}";

    # sensord owns net.hadess.SensorProxy; the stock iio-sensor-proxy would
    # compete for the same bus name.
    hardware.sensor.iio.enable = lib.mkIf cfg.sensord.enable (lib.mkForce false);

    systemd.services.zhiyu-sensord = lib.mkIf cfg.sensord.enable {
      description = "SensorProxy daemon backed by sensh/SNS Client";
      after = [ "hexagonrpcd-adsp-sensorspd.service" ];
      wants = [ "hexagonrpcd-adsp-sensorspd.service" ];
      before = [
        "iio-sensor-proxy.service"
        "upower.service"
        "display-manager.service"
      ];
      serviceConfig = {
        Type = "notify";
        NotifyAccess = "all";
        TimeoutStartSec = 30;
        # The fastrpc driver only autoloads on machine-specific udev events;
        # loading it here guarantees /dev/fastrpc-adsp exists before sensh
        # talks to the ADSP.
        ExecStartPre = [
          "-${pkgs.kmod}/bin/modprobe -q fastrpc"
          "-${pkgs.kmod}/bin/modprobe -q uinput"
        ];
        ExecStart = "${sensord}/bin/zhiyu-sensord";
        # UPower retains an open evdev fd across device removal; refresh it on
        # hot restart.
        ExecStartPost = "-${pkgs.systemd}/bin/systemctl try-restart --no-block upower.service";
        Restart = "always";
        RestartSec = 2;
      };
      wantedBy = [ "multi-user.target" ];
    };

    # A ramdisk without the selected kernel's modules output cannot work.
    environment.etc."machine-info".text = "CHASSIS=tablet\n";
    zramSwap.enable = true;

    assertions = [
      {
        assertion = !cfg.camera.enable || pkgs.libcamera.version == "0.7.2";
        message = "zhiyu: libcamera-zhiyu is pinned to 0.7.2; update the fork and check the ABI";
      }
      {
        assertion = lib.versionAtLeast pkgs.mesa.version "26";
        message = "zhiyu: Mesa 26 or newer is required for the Freedreno/Rusticl stack";
      }
      {
        assertion = kernel.modules or null != null;
        message = "zhiyu: boot.kernelPackages.kernel must provide a modules output";
      }
    ];

    hardware.graphics.extraPackages = [
      qcomVaDriver
      pkgs.mesa.opencl
    ];
    environment.sessionVariables = {
      LIBVA_DRIVERS_PATH = "/run/opengl-driver/lib/dri";
      RUSTICL_ENABLE = "freedreno";
    };

    # Each generation keeps the images it was built with, so rolling back a
    # generation also brings back its matching boot images.
    system.extraDependencies = [ images.bundle ];
    environment.etc."zhiyu/boot-images".source = images.bundle;
    environment.etc."zhiyu/boot-id".text = images.bootId + "\n";
    environment.systemPackages = [
      flasher
      pkgs.qbootctl
    ]
    ++ lib.optionals cfg.camera.enable [ pkgs.libcamera-zhiyu ];

    boot.loader.external = lib.mkIf cfg.flashOnSwitch {
      enable = true;
      installHook = "${flasher}/bin/zhiyu-install";
    };

    system.build.zhiyuKernel = kernel;
    system.build.zhiyuInitramfs = initramfs;
    system.build.zhiyuFirmware = firmware;
    system.build.zhiyuBoot = images.boot;
    system.build.zhiyuVendorBoot = images.vendorBoot;
    system.build.zhiyuInitBoot = images.initBoot;
    system.build.zhiyuVbmeta = images.vbmeta;
    system.build.zhiyuImages = images.bundle;
  };
}
