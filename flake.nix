{
  description = "Reproducible barebox verified-boot reference bootchain on QEMU's imx8mm-evk";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    # barebox release. Keep the version in sync with the tag: it is also parsed
    # out of the Makefile below and used as the package version.
    barebox-src = {
      url = "github:barebox/barebox/v2026.08.0";
      flake = false;
    };

    # labgrid master: QEMUDriver.interact() (used by scripts/run.py) is not
    # part of a release yet.
    labgrid-src = {
      url = "github:labgrid-project/labgrid/424a0b708ca5d48b1a6e65722d2910a6d0c8751d";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      barebox-src,
      labgrid-src,
    }:
    let
      versions = import ./versions.nix;

      # Security policies compiled into barebox; one build per policy,
      # differing only in which policy is active at boot.
      policies = [
        "lockdown"
        "factory"
        "devel"
      ];
      defaultPolicy = "factory";

      # The redundant boot slots. Each is a bootchooser target <target> whose
      # boot script config/env/barebox/boot/<target> boots the signed FIT from
      # the GPT partition <partition>; priorities and remaining attempt
      # counters live in the barebox state instance on the same card (the
      # state node in pkgs/barebox/0003-*.patch).
      slots = [
        {
          target = "system0";
          partition = "kernel0";
          uuid = "7b1a3c52-1c2e-4a6f-9e0b-2f7d0f2c1a03";
        }
        {
          target = "system1";
          partition = "kernel1";
          uuid = "7b1a3c52-1c2e-4a6f-9e0b-2f7d0f2c1a04";
        }
      ];

      forSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
      ];

      bareboxVersion =
        let
          m = builtins.match ".*\nVERSION = ([0-9]+)\nPATCHLEVEL = ([0-9]+)\nSUBLEVEL = ([0-9]+)\nEXTRAVERSION =([^\n]*)\n.*" (
            builtins.readFile "${barebox-src}/Makefile"
          );
        in
        assert m != null;
        "${builtins.elemAt m 0}.${builtins.elemAt m 1}.${builtins.elemAt m 2}${
          nixpkgs.lib.removePrefix " " (builtins.elemAt m 3)
        }";

      mkOutputs =
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          inherit (pkgs) lib;

          qemu =
            lib.throwIfNot (lib.versionAtLeast pkgs.qemu.version versions.qemuMinimum)
              "QEMU ${pkgs.qemu.version} from nixpkgs is older than ${versions.qemuMinimum}, which introduced the imx8mm-evk machine"
              pkgs.qemu;

          toolchain = pkgs.callPackage ./pkgs/toolchain.nix { inherit (versions) toolchain; };

          labgrid = pkgs.python3Packages.labgrid.overridePythonAttrs (old: {
            version = "26.1.dev81";
            src = labgrid-src;
            doCheck = false;
          });
          pythonEnv = pkgs.python3.withPackages (ps: [
            labgrid
            ps.pytest
          ]);

          devKey = {
            hint = "dev";
            crt = ./keys/dev.crt;
          };
          policyFile = p: ./config/policies + "/imx8mm-evk-qemu-${p}.sconfig";

          # One barebox build per security policy; they differ only in which
          # policy is active at boot (CONFIG_SECURITY_POLICY_INIT).
          bareboxFor =
            policy:
            pkgs.callPackage ./pkgs/barebox.nix {
              inherit toolchain;
              pname = "barebox-${policy}";
              src = barebox-src;
              version = bareboxVersion;
              patches = [
                ./pkgs/barebox/0001-ARM-dts-imx8mm-evk-add-QEMU-variant.patch
                ./pkgs/barebox/0002-Makefile-fix-security_-config-configurator-targets.patch
                ./pkgs/barebox/0003-ARM-dts-imx8mm-evk-qemu-add-A-B-boot-state.patch
              ];
              defconfig = ./config/barebox/imx8mm-evk-qemu_defconfig;
              extraConfig = ''CONFIG_SECURITY_POLICY_INIT="${policy}"'';
              defaultEnv = ./config/env/barebox;
              policies = map policyFile policies;
              publicKeys = [ devKey ];
              # Real DDR/TF-A firmware can be supplied here to make the i.MX
              # image flashable; see README, "The PBL and the boot ROM".
              firmware = null;
              artifacts = [
                # generic DT image (PBL + barebox proper), started by QEMU -kernel
                "images/barebox-dt-2nd.img"
                # the real i.MX8MM EVK image the boot ROM would load (flash
                # header + PBL + barebox proper); not bootable under QEMU
                "images/barebox-nxp-imx8mm-evk.img"
                "arch/arm/dts/imx8mm-evk-qemu.dtb"
              ];
            };

          # config/policies/*.sconfig after `make security_olddefconfig` and
          # config/barebox/*_defconfig after `make savedefconfig`; copy the
          # result back into the repository after changing a policy or the
          # barebox configuration, or after bumping barebox.
          configs-normalized = (bareboxFor defaultPolicy).override { normalizeConfigsOnly = true; };

          linux = pkgs.callPackage ./pkgs/debian-kernel.nix { inherit (versions) debianKernel; };
          initramfs = pkgs.callPackage ./pkgs/initramfs.nix { inherit (versions) busybox; };
          linuxGz = pkgs.runCommand "linux-image-gz" { } ''
            mkdir -p $out
            gzip -n -9 -c ${linux}/Image > $out/Image.gz
          '';

          # Linux' device tree comes from the signed FIT, not from QEMU, so the
          # fixups QEMU's board code would apply are done here.
          linuxDtb = pkgs.callPackage ./pkgs/qemu-dtb-fixups.nix { dtb = "${linux}/imx8mm-evk.dtb"; };

          # One signed FIT per slot. Both hold the same kernel, device tree
          # and initramfs and differ only in their description, which barebox
          # prints when it opens the image ("Opened FIT image: ...").
          fitFor =
            slot:
            pkgs.callPackage ./pkgs/fit-image.nix {
              name = "linux-${slot.target}";
              its = ./config/fit/linux.its;
              substitutions = {
                KERNEL = "${linuxGz}/Image.gz";
                DTB = "${linuxDtb}/imx8mm-evk.dtb";
                INITRAMFS = "${initramfs}/initramfs.cpio.gz";
                SLOT = slot.target;
              };
              keys = ./keys;
            };

          # The SD card. barebox's device tree reserves the first MiB for the
          # raw bootloader image (33 KiB, where the boot ROM looks) and the raw
          # barebox environment; the state and the two signed FITs live in GPT
          # partitions after it.
          disk-image = pkgs.callPackage ./pkgs/disk-image.nix {
            sizeMiB = 128;
            diskUuid = "7b1a3c52-1c2e-4a6f-9e0b-2f7d0f2c1a01";
            partitions = [
              {
                # found by its type GUID, not by name: barebox looks up
                # BAREBOX_STATE_PARTITION_GUID on the device the state node's
                # "backend" phandle points at. Shipped zeroed, barebox
                # initializes it from the defaults in the device tree.
                name = "state";
                type = "4778ed65-bf42-45fa-9c5b-287a1dc4aab1";
                sizeMiB = 1;
                uuid = "7b1a3c52-1c2e-4a6f-9e0b-2f7d0f2c1a02";
              }
            ]
            ++ map (slot: {
              name = slot.partition;
              image = "${fitFor slot}/linux-${slot.target}.fit";
              sizeMiB = 48;
              inherit (slot) uuid;
            }) slots;
          };

          # Everything the labgrid environment needs, in one directory
          imagesFor =
            policy:
            pkgs.runCommand "bootchain-images-${policy}" { } ''
              mkdir -p $out
              ln -s ${bareboxFor policy}/barebox-dt-2nd.img $out/barebox.img
              ln -s ${bareboxFor policy}/imx8mm-evk-qemu.dtb $out/imx8mm-evk-qemu.dtb
              ln -s ${disk-image}/disk.img $out/disk.img
              # for reference / real hardware, not used under QEMU
              ln -s ${bareboxFor policy}/barebox-nxp-imx8mm-evk.img $out/barebox-nxp-imx8mm-evk.img
              ${lib.concatMapStringsSep "\n" (
                slot: "ln -s ${fitFor slot}/linux-${slot.target}.fit $out/linux-${slot.target}.fit"
              ) slots}
            '';

          runFor =
            policy:
            pkgs.writeShellApplication {
              name = "bootchain-run-${policy}";
              runtimeInputs = [
                qemu
                pythonEnv
                pkgs.microcom
              ];
              text = ''
                export LG_IMAGES=${imagesFor policy}
                exec python3 ${./scripts/run.py} --config ${./labgrid}/imx8mm-evk-qemu.yaml "$@"
              '';
            };

          testFor =
            policy:
            pkgs.writeShellApplication {
              name = "bootchain-test-${policy}";
              runtimeInputs = [
                qemu
                pythonEnv
              ];
              text = ''
                export LG_IMAGES=${imagesFor policy}
                export BOOTCHAIN_POLICY=${policy}
                exec pytest -p no:cacheprovider --lg-env ${./labgrid}/imx8mm-evk-qemu.yaml ${./tests} "$@"
              '';
            };

          perPolicy =
            f:
            lib.listToAttrs (
              map (p: {
                name = p;
                value = f p;
              }) policies
            );
          prefixed = prefix: attrs: lib.mapAttrs' (n: v: lib.nameValuePair "${prefix}-${n}" v) attrs;
        in
        {
          packages =
            {
              inherit
                toolchain
                configs-normalized
                linux
                linuxDtb
                initramfs
                disk-image
                qemu
                ;
              labgrid = pythonEnv;
              default = imagesFor defaultPolicy;
            }
            // lib.listToAttrs (
              map (slot: lib.nameValuePair "fit-linux-${slot.target}" (fitFor slot)) slots
            )
            // prefixed "barebox" (perPolicy bareboxFor)
            // prefixed "images" (perPolicy imagesFor)
            // prefixed "run" (perPolicy runFor)
            // prefixed "test" (perPolicy testFor);

          apps =
            let
              app = drv: {
                type = "app";
                program = lib.getExe drv;
              };
            in
            {
              default = app (runFor defaultPolicy);
            }
            // prefixed "run" (perPolicy (p: app (runFor p)))
            // prefixed "test" (perPolicy (p: app (testFor p)));

          # Boot the whole chain under QEMU (TCG) inside the sandbox and run
          # the test suite against it.
          checks = perPolicy (
            policy:
            pkgs.runCommand "bootchain-check-${policy}" { nativeBuildInputs = [ (testFor policy) ]; } ''
              set -o pipefail
              export HOME=$TMPDIR
              cd $TMPDIR
              bootchain-test-${policy} --lg-log=lg-log -v 2>&1 | tee $TMPDIR/pytest.log
              mkdir -p $out
              cp -r $TMPDIR/pytest.log lg-log $out/
            ''
          );

          devShells.default = pkgs.mkShell {
            packages = [
              toolchain
              qemu
              pythonEnv
              pkgs.ubootTools
              pkgs.dtc
              pkgs.microcom
              pkgs.openssl
              pkgs.util-linux
            ];
            env = {
              ARCH = "arm";
              CROSS_COMPILE = toolchain.crossCompile;
              LG_ENV = "${./labgrid}/imx8mm-evk-qemu.yaml";
              LG_IMAGES = imagesFor defaultPolicy;
            };
          };

          formatter = pkgs.nixfmt-tree;
        };
    in
    {
      packages = forSystems (system: (mkOutputs system).packages);
      apps = forSystems (system: (mkOutputs system).apps);
      checks = forSystems (system: (mkOutputs system).checks);
      devShells = forSystems (system: (mkOutputs system).devShells);
      formatter = forSystems (system: (mkOutputs system).formatter);
    };
}
