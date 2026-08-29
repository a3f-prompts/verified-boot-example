# barebox verified-boot example

A reproducible, fully virtualized reference bootchain for security assessment
of [barebox](https://barebox.org):

```
QEMU imx8mm-evk ──-kernel──▶ barebox PBL ──▶ barebox proper ──boot /dev/mmc1.kernel──▶ Linux
                             (stands in for      (security policy        signed FIT on a
                              what the boot ROM   lockdown/factory/devel)  raw GPT partition
                              loads)
```

Every component is pinned to an exact version and nothing is built from
source except barebox itself and the images around it:

| Component                | Version                  | Pinned by                       |
|--------------------------|--------------------------|---------------------------------|
| barebox                  | v2026.08.0 (+2 patches)  | `flake.lock` (`barebox-src`)    |
| aarch64 cross toolchain  | GCC 15.2.0, kernel.org crosstool (binary) | `versions.nix` |
| QEMU                     | ≥ 11.1.0 (`imx8mm-evk`)  | `flake.lock` (`nixpkgs`), asserted in `flake.nix` |
| mkimage (`ubootTools`)   | 2026.07                  | `flake.lock` (`nixpkgs`)        |
| labgrid                  | master 424a0b70 (`QEMUDriver.interact()`) | `flake.lock` (`labgrid-src`) |
| Linux kernel             | Debian trixie 6.12.94-1 arm64 (signed .deb) | `versions.nix` |
| busybox (initramfs)      | Debian 1.37.0-6+b8 static | `versions.nix`                 |

`nix flake metadata` / `nix eval .#packages.x86_64-linux.qemu.version` show the
resolved versions.

## Quick start

```sh
nix run                      # build everything, boot the chain, attach a console
nix run .#run-lockdown       # same with barebox in the "lockdown" policy
nix run . -- --state linux   # boot all the way to the initramfs shell first
nix run . -- --dry-run       # print the QEMU command line
nix run .#test-factory       # run the labgrid/pytest suite
nix flake check              # build everything + boot-test all three policies
```

Leave the interactive console with `Ctrl-\` followed by `q` (microcom).

Interactive use needs a policy that permits console input; the default
(`factory`) does, `lockdown` does not. With `lockdown` you can watch the chain
boot straight into Linux and then use the initramfs shell.

Without Nix on the host, everything also runs from the `nixos/nix` container:

```sh
podman run --rm -it -v bvbe-nix:/nix -v "$PWD":/work -w /work \
    -e NIX_CONFIG="experimental-features = nix-command flakes" \
    docker.io/nixos/nix nix run .#test-factory
```

## What is where

```
flake.nix                 wiring: barebox variants, FIT image, disk image, run/test apps, checks
versions.nix              hashes/URLs of all prebuilt binaries (toolchain, kernel, busybox)
pkgs/toolchain.nix        kernel.org crosstool tarball, patchelf'ed (no compiler build)
pkgs/barebox.nix          generic barebox builder (defconfig + fragments + policies + keys + env)
pkgs/barebox/*.patch      barebox patches: imx8mm-evk-qemu.dts, security_%config Makefile fix
pkgs/debian-kernel.nix    Image + imx8mm-evk.dtb out of the Debian .deb
pkgs/qemu-dtb-fixups.nix  the DTB fixups QEMU's board code would apply (Linux' DTB comes from the FIT)
pkgs/initramfs.nix        busybox initramfs
pkgs/fit-image.nix        mkimage -f its -k keys
pkgs/disk-image.nix       GPT SD card image with the "kernel" partition
config/barebox/*.config   Kconfig fragment on top of imx_v8_defconfig
config/policies/*.sconfig security policies: lockdown, factory, devel
config/env/barebox        environment overlay: boot entry "fit", nv variables (boot target, bootargs)
config/fit/*.its          FIT image source (Linux)
keys/                     development signing key (see keys/README.md)
labgrid/                  labgrid environment + strategy
scripts/run.py            interactive runner (labgrid examples/qemu-run.py, extended)
tests/                    pytest suite driving the chain through labgrid
```

## Flake outputs

| Output                          | Content                                                      |
|---------------------------------|--------------------------------------------------------------|
| `toolchain`                     | aarch64-linux GCC                                            |
| `barebox-<policy>`              | `barebox-dt-2nd.img` (what QEMU boots), `barebox-nxp-imx8mm-evk.img` (the real ROM-loadable image, see below), `imx8mm-evk-qemu.dtb`; all three policies compiled in, `<policy>` active |
| `fit-linux`                     | signed FIT: kernel (gzip) + DTB + initramfs                  |
| `disk-image`                    | 64 MiB GPT SD-card image                                     |
| `images-<policy>` (default)     | directory with everything the labgrid environment references |
| `run-<policy>`, `test-<policy>` | wrappers setting `$LG_IMAGES` around `scripts/run.py` / pytest |
| `checks.<policy>`               | boot test in the Nix sandbox (QEMU TCG)                      |
| `policies-normalized`           | `config/policies/*.sconfig` in canonical form (see "Updating pins") |
| `devShells.default`             | toolchain, QEMU, labgrid, mkimage, dtc, … with `$CROSS_COMPILE`, `$LG_ENV`, `$LG_IMAGES` set |

`<policy>` is one of `lockdown`, `factory`, `devel`.

## The bootchain in detail

**barebox** is one build per policy (`barebox-<policy>`): `imx_v8_defconfig`
plus `config/barebox/bootchain.config`, with all three policies from
`config/policies/` compiled in and `CONFIG_SECURITY_POLICY_INIT=<policy>`.
The public key is compiled in
(`CONFIG_CRYPTO_PUBLIC_KEYS="keyring=fit,fit-hint=dev:…/dev.crt"`). Unsigned
images are only allowed if the active policy says so
(`SCONFIG_BOOT_UNSIGNED_IMAGES`, set in `devel` only). After a short autoboot
timeout barebox proper runs the boot entry `fit` (`nv.boot.default`,
`config/env/barebox/boot/fit`), i.e. `bootm /dev/mmc1.kernel`, the signed FIT
on the raw partition, verifying the configuration signature
(`sha256,rsa4096`, key name hint `dev`; kernel, fdt and ramdisk hashes are
covered) before starting Linux. `nv.bootm.verbose=1` makes it print the
verification result on every boot, not only for `boot -v`.

**The SD card** (`disk-image`) is a raw GPT image on uSDHC2 (QEMU
`-drive if=sd,bus=1,unit=0`), the SD slot of the real board. barebox's own
device tree reserves the first MiB as fixed partitions — `barebox` (0–896 KiB,
where the boot ROM expects the bootloader image at 33 KiB) and
`barebox-environment` (896 KiB–1 MiB, the raw environment barebox loads if
the policy allows `SCONFIG_ENVIRONMENT_LOAD`) — so the GPT partition table
and the FIT partition follow after that:

| Partition | Offset | Size   | Content                                       |
|-----------|--------|--------|-----------------------------------------------|
| `kernel`  | 1 MiB  | 48 MiB | `linux.fit`: Debian kernel + `imx8mm-evk.dtb` + initramfs |

GPT partition *labels* are what barebox exposes as `/dev/mmc1.<label>`. The
partition holds the bare FIT, no filesystem.

### The PBL and the boot ROM

On the real i.MX8MM EVK the chain starts in the SoC's boot ROM: it loads the
first ~250 KiB of `barebox-nxp-imx8mm-evk.img` from the SD card (offset
33 KiB) into on-chip TCM at `0x7e1000` and jumps to the barebox PBL. The
PBL initializes DDR, loads the full image (PBL + compressed barebox proper)
from the card into DRAM through the uSDHC controller
(`arch/arm/mach-imx/xload-common.c`, `drivers/mci/imx-esdhc-pbl.c`), runs
TF-A, and re-enters itself in DRAM at EL2 where it decompresses and starts
barebox proper. HABv4 authenticates the ROM-loaded part.

QEMU's `imx8mm-evk` cannot run that image today: the boot-ROM region is an
unimplemented-device stub and `-bios` is ignored, the DDR controller, PLLs
and PMIC I²C that the EVK PBL programs are not modelled, and there is no
TF-A. What QEMU boots instead is `barebox-dt-2nd.img` via `-kernel`: the
same barebox proper behind a *generic* PBL that takes the device tree from
QEMU (`imx8mm-evk-qemu.dtb`, `imx8mm-evk.dts` with the DDRC node disabled,
carried as `pkgs/barebox/0001-*`) instead of touching hardware. So the
PBL→proper hand-off happens inside the image QEMU loads into DRAM rather
than through the SD card.

The real image is nevertheless built and installed next to it
(`barebox-nxp-imx8mm-evk.img` in every `barebox-<policy>` / `images-<policy>`
output), with the *same* barebox proper, environment, keys and policies. It
is built against barebox's dummy firmware blobs (`test/generate-dummy-fw.sh`,
what upstream CI uses) unless real DDR-training firmware and TF-A BL31 are
passed to `pkgs/barebox.nix` via the `firmware` argument (NXP `firmware-imx`
is EULA-covered and is not fetched here); with dummy firmware it is
structurally complete but must not be flashed. Making QEMU start from that
image — a QEMU-specific PBL entry that skips DDR/PMIC/TF-A and loads barebox
proper from uSDHC2 like the EVK PBL does, started through
`-device loader,…,cpu-num=0` at the ROM's load address — is the obvious next
step and is deliberately not part of this repository yet.

**Further QEMU specifics.** The console is UART2, so the first `-serial` is
`null`. Linux is booted with the upstream `imx8mm-evk.dtb` from Debian's
kernel package, after the same fixups QEMU applies to a DTB it loads itself
(`hw/arm/imx8mm-evk.c`: nop the FlexSPI/MIPI nodes, drop `cpu-idle-states`;
`pkgs/qemu-dtb-fixups.nix`) — without them the kernel hangs in
`armv8_pmu_driver_init`. Other peripherals QEMU does not implement are
stubbed and simply do not probe. `pkgs/barebox/0002-*`
fixes the `make security_%config` policy configurators in barebox v2026.08.0
(they were dispatched to Kconfig and, once reached, collected no policies);
the build relies on `security_olddefconfig` to normalize the policy files.

### Known emulation issues

* **Multi-block SD transfers with DMA lose their last sector — a QEMU
  bug.** With barebox's SDMA path (`sdhci_transfer_data_dma()`), every
  128-sector transfer through QEMU's uSDHC model comes back with the final
  512-byte sector stale while all other sectors are intact (found with
  `crc32 -f /dev/mmc1.kernel <off>+<len>` against the host image; the FIT
  then fails its `hash-1` checks although the configuration signature,
  which only covers the hash *values*, verifies).

  QEMU starts an SDMA transfer on *any* write to the last byte of the SDMA
  System Address register as long as block count and block size are
  non-zero and SDMA is selected (`hw/sd/sdhci.c`, `sdhci_write()`, `case
  SDHC_SYSAD`). On real hardware such a write only *resumes* a transfer
  that the controller suspended at a Host SDMA Buffer Boundary; a transfer
  is started by writing the Command register. barebox programs block size
  and count before the DMA address — legal, just not the order the spec's
  transaction sequence and Linux use — so its setup write looks like a
  resume to QEMU: a spurious single-block transfer runs before the command
  is issued, hands the card's dummy data to memory, decrements the block
  count and ends the "transfer". The following CMD18/CMD25 then moves only
  127 of the 128 blocks. `-d guest_errors` shows this as
  `sd_read_data: not in Sending-Data state` right before the CMD18.

  Until QEMU is fixed, barebox is built with `CONFIG_MCI_IMX_ESDHC_PIO=y`,
  which transfers correctly. Real hardware is not affected by the
  workaround, only slower. Drop the option to reproduce.
* `imx8mm-evk` needs an explicit `-dtb`; QEMU does not synthesize one.
* `-drive if=sd` must be addressed as `bus=<uSDHC index>,unit=0`; `index=N`
  is rejected for this machine.

## Security assessment notes

* The private signing key is in `keys/` and must be treated as public. In
  scope: anything that boots a payload *not* signed with it, or that weakens
  the policy boundaries. Out of scope: "sign a malicious payload with dev.key".
* The trust anchor of the emulated chain is the barebox image QEMU loads
  (not verified by anything). On real silicon this role is played by the
  boot ROM and HABv4.
* Attack surface reachable without a shell: the SD card contents (GPT
  parsing, the raw FIT — FIT parsing, hash/signature checks, gzip
  decompression), the raw environment partition (only if a policy sets
  `SCONFIG_ENVIRONMENT_LOAD`), and whatever the emulated peripherals expose.
  Note that the configuration signature covers the *hash values* of the
  images, not the image bytes; integrity of the bytes rests on the per-image
  `hash-1` checks that barebox performs after the signature check.
* Each policy is a separate build (`barebox-<policy>`); there is intentionally
  no runtime policy switch (`CMD_SCONFIG_MODIFY` is off).
* Everything is deterministic given `flake.lock` + `versions.nix`; a finding
  can be reported against the store path (`nix path-info .#images-factory`)
  of the images it was reproduced with.

## Updating pins

* barebox / labgrid: edit the input URL in `flake.nix`, run `nix flake lock`.
  (The barebox patches in `pkgs/barebox/` may need rebasing.)
* Security policies: barebox refuses to build with `.sconfig` files that are
  not in the canonical form `make security_olddefconfig` produces, and that
  form depends on the Kconfig configuration (symbols whose dependencies are
  off disappear). After editing a policy or changing the barebox
  configuration, run `nix build .#policies-normalized` and copy
  `result/*.sconfig` into `config/policies/`.
* nixpkgs (QEMU, mkimage, dtc, Python, …): `nix flake update nixpkgs`. The
  QEMU minimum version is checked at evaluation time.
* Toolchain, kernel, busybox: edit URL and hash in `versions.nix`
  (`nix hash convert --hash-algo sha256 --to sri <hex>` turns a plain sha256
  into the SRI form).

## License

The Nix expressions, scripts and configuration files in this repository are
MIT licensed (see `LICENSE`). This does not extend to the artifacts they
build, nor to the barebox patches under `pkgs/barebox/`, which are derivative
works of barebox and thus GPL-2.0-only.
