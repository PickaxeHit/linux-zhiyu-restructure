{
  description = "Mainline Linux for the Lenovo TB378FC (zhiyu, SM8750P)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      # Built on the board itself (or any aarch64 builder): every package is a
      # native aarch64 build, so the official binary cache is used directly and
      # no cross toolchain is involved.
      systems = [ "aarch64-linux" ];
    in
    {
      packages = lib.genAttrs systems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          kernel = pkgs.callPackage ./nix/kernel.nix { };
          keymint = pkgs.callPackage ./nix/keymint.nix { };
          sensh = pkgs.callPackage ./nix/sensh.nix { };
          sensord = pkgs.callPackage ./nix/sensord.nix { inherit sensh; };

          firmware = pkgs.callPackage ./nix/firmware.nix { };
          udevRules = pkgs.callPackage ./nix/udev-rules.nix { };
          ucm2 = pkgs.callPackage ./nix/ucm2.nix { };
          flasher = pkgs.callPackage ./nix/flasher.nix { };
          qcomVaDriver = pkgs.callPackage ./nix/qcom-va-driver.nix { };
          qcomSensors = pkgs.callPackage ./nix/qcom-sensors.nix { };

          dts = pkgs.callPackage ./nix/dts.nix {
            inherit kernel;
            dts = ./dts/lenovo-zhiyu.dts;
          };

          initramfs = pkgs.callPackage ./nix/initramfs.nix {
            inherit kernel keymint firmware;
          };

          images = pkgs.callPackage ./nix/images.nix {
            inherit kernel initramfs;
            dtb = dts;
          };
        in
        {
          inherit
            kernel
            dts
            keymint
            firmware
            initramfs
            sensh
            sensord
            udevRules
            ucm2
            flasher
            qcomVaDriver
            qcomSensors
            ;
          # One image per partition; the bundle is what gets flashed and what
          # scripts/update-boot-images.sh expects.
          zhiyu-boot = images.boot;
          zhiyu-vendor-boot = images.vendorBoot;
          zhiyu-init-boot = images.initBoot;
          zhiyu-vbmeta = images.vbmeta;
          zhiyu-images = images.bundle;
          zhiyu-ucm2 = ucm2;
          zhiyu-install = flasher;
          qcom-va-driver = qcomVaDriver;
          qcom-sensors = qcomSensors;
          default = images.bundle;
        }
      );

      checks = lib.genAttrs systems (
        system:
        let
          inherit (self.packages.${system}) dts firmware;
        in
        {
          inherit dts firmware;
          images = self.packages.${system}.zhiyu-images;
        }
      );

      nixosModules.default = ./nix/nixos-module.nix;

      # The complete system, built natively on aarch64.
      nixosConfigurations.zhiyu = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        modules = [ ./nixos/configuration.nix ];
      };

      # Formatting is a developer convenience, not a cross build: it follows the
      # machine it runs on.
      formatter = lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (
        system: nixpkgs.legacyPackages.${system}.nixfmt
      );
    };
}
