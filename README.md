# barebox verified-boot example

A reproducible, fully virtualized reference bootchain for security assessment
of [barebox](https://barebox.org):

```
                                                            ┌─bootchooser─▶ /dev/mmc1.kernel0 ─┐
QEMU imx8mm-evk ──-kernel──▶ barebox PBL ──▶ barebox proper ─┤  (A/B state  │                  ├─▶ Linux
                             (stands in for  (security policy│  on the card)└▶ /dev/mmc1.kernel1┘
                              what the boot    lockdown/                       signed FIT on a
                              ROM loads)       factory/devel)                  raw GPT partition
```

Every component is pinned to an exact version and nothing is built from
source except barebox itself and the images around it:

| Component                | Version                  | Pinned by                       |
|--------------------------|--------------------------|---------------------------------|
| barebox                  | v2026.08.0 (+3 patches)  | `flake.lock` (`barebox-src`)    |
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

At the barebox prompt, the A/B state is what decides where the chain goes:

```sh
bootchooser -i                # priorities and remaining attempts of both slots
state; devinfo state          # the variable set behind them
bootchooser -p 30 system1     # make slot B win the next boot
boot                          # ... and take it
```

The SD card is opened in QEMU's snapshot mode, so such changes are written to
the card but discarded when QEMU exits.

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
pkgs/barebox.nix          generic barebox builder (defconfig + policies + keys + env)
pkgs/barebox/*.patch      barebox patches: imx8mm-evk-qemu.dts, security_%config Makefile fix, A/B state node
pkgs/debian-kernel.nix    Image + imx8mm-evk.dtb out of the Debian .deb
pkgs/qemu-dtb-fixups.nix  the DTB fixups QEMU's board code would apply (Linux' DTB comes from the FIT)
pkgs/initramfs.nix        busybox initramfs
pkgs/fit-image.nix        mkimage -f its -k keys
pkgs/disk-image.nix       GPT SD card image with the "state" and "kernel0"/"kernel1" partitions
config/barebox/*_defconfig  barebox configuration (a full defconfig, not a fragment)
config/policies/*.sconfig security policies: lockdown, factory, devel
config/env/barebox        environment overlay: boot entries "system0"/"system1", nv variables (bootchooser, bootargs)
config/fit/*.its          FIT image source (Linux), instantiated once per slot
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
| `fit-linux-<slot>`              | signed FIT: kernel (gzip) + DTB + initramfs, one per A/B slot |
| `disk-image`                    | 128 MiB GPT SD-card image                                    |
| `images-<policy>` (default)     | directory with everything the labgrid environment references |
| `run-<policy>`, `test-<policy>` | wrappers setting `$LG_IMAGES` around `scripts/run.py` / pytest |
| `checks.<policy>`               | boot test in the Nix sandbox (QEMU TCG)                      |
| `configs-normalized`            | `config/policies/*.sconfig` and the defconfig in canonical form (see "Updating pins") |
| `devShells.default`             | toolchain, QEMU, labgrid, mkimage, dtc, … with `$CROSS_COMPILE`, `$LG_ENV`, `$LG_IMAGES` set |

`<policy>` is one of `lockdown`, `factory`, `devel`; `<slot>` is `system0` or
`system1`.

## The bootchain in detail

**barebox** is one build per policy (`barebox-<policy>`):
`config/barebox/imx8mm-evk-qemu_defconfig` — a dedicated defconfig, derived
from barebox' `imx_v8_defconfig` but with only the i.MX8MM EVK board — with
all three policies from `config/policies/` compiled in and
`CONFIG_SECURITY_POLICY_INIT=<policy>`. The public key is compiled in
(`CONFIG_CRYPTO_PUBLIC_KEYS="keyring=fit,fit-hint=dev:…/dev.crt"`). Unsigned
images are only allowed if the active policy says so
(`SCONFIG_BOOT_UNSIGNED_IMAGES`, set in `devel` only). After a short autoboot
timeout barebox proper runs the boot entry `bootchooser` (`nv.boot.default`),
which picks a slot and runs `config/env/barebox/boot/<slot>`, i.e.
`bootm /dev/mmc1.kernel0` or `bootm /dev/mmc1.kernel1`, the signed FIT on the
raw partition, verifying the configuration signature (`sha256,rsa4096`, key
name hint `dev`; kernel, fdt and ramdisk hashes are covered) before starting
Linux. `nv.bootm.verbose=1` makes it print which image it opened and the
verification result on every boot, not only for `boot -v`.

**A/B boot.** Which of the two slots is booted is decided by barebox'
[bootchooser](https://www.barebox.org/doc/latest/user/bootchooser.html), whose
static configuration is in `config/env/barebox/nv/bootchooser.*`:

| Variable                                | Value              |
|-----------------------------------------|--------------------|
| `bootchooser.targets`                   | `system0 system1`  |
| `bootchooser.state_prefix`              | `state.bootstate`  |
| `bootchooser.system0.default_priority`  | 20                 |
| `bootchooser.system1.default_priority`  | 10                 |
| `bootchooser.system{0,1}.default_attempts` | 3               |
| `bootchooser.retry`                     | 1                  |
| `bootchooser.reset_attempts`            | `all-zero`         |
| `bootchooser.reset_priorities`          | `all-zero`         |

The variable data it works on — a `priority` and a `remaining_attempts`
counter per target, plus `last_chosen` — lives in a barebox
[state](https://www.barebox.org/doc/latest/user/state.html) variable set
described by the device tree node added by `pkgs/barebox/0003-*.patch`. Every
boot decrements the counter of the chosen target and writes the state back to
the card, so a slot that never comes up far enough to have its counter reset
(`bootchooser -s` in barebox, `barebox-state -s bootstate.system0.remaining_attempts=3`
from Linux userspace) is retried three times and then skipped in favour of the
other one. The two `all-zero` resets keep the demo from ending up with nothing
left to boot: once every target is exhausted or disabled, the defaults from
the device tree are restored. barebox also puts `bootchooser.active=<target>`
on the kernel command line, and copies the state description into the device
tree it hands to Linux so that userspace sees the same variable set.

The `state` backend is the *device*, not a fixed partition: barebox resolves a
block device backend to the GPT partition whose type GUID is
`4778ed65-bf42-45fa-9c5b-287a1dc4aab1`. Its storage type is `direct`, the one
for backends that need no erase — three copies of the variable set are written
side by side, `backend-stridesize` (0x40) bytes apart, each 8 bytes of bucket
meta data plus a 16-byte `raw` header plus 20 bytes of data.

The two slots hold the same kernel, device tree and initramfs; only the FIT
`description` differs (`… slot system0` / `… slot system1`), so the boot log
says which of the two partitions was read.

**The SD card** (`disk-image`) is a raw GPT image on uSDHC2 (QEMU
`-drive if=sd,bus=1,unit=0`), the SD slot of the real board. barebox's own
device tree reserves the first MiB as fixed partitions — `barebox` (0–896 KiB,
where the boot ROM expects the bootloader image at 33 KiB) and
`barebox-environment` (896 KiB–1 MiB, the raw environment barebox loads if
the policy allows `SCONFIG_ENVIRONMENT_LOAD`) — so the GPT partition table
and the payload partitions follow after that:

| Partition | Offset | Size   | Content                                       |
|-----------|--------|--------|-----------------------------------------------|
| `state`   | 1 MiB  | 1 MiB  | A/B boot state; shipped zeroed, barebox initializes it from the defaults in its device tree |
| `kernel0` | 2 MiB  | 48 MiB | `linux-system0.fit`: Debian kernel + `imx8mm-evk.dtb` + initramfs |
| `kernel1` | 50 MiB | 48 MiB | `linux-system1.fit`: the same, for the second slot |

GPT partition *labels* are what barebox exposes as `/dev/mmc1.<label>`. The
kernel partitions hold the bare FIT, no filesystem. QEMU opens the image in
snapshot mode (the Nix store is read-only), so barebox' writes to the state
partition survive within a QEMU run but not across one.

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
`pkgs/barebox/0003-*` adds the A/B state node to the QEMU device tree; it is
a property of this bootchain rather than of the machine, hence a patch of its
own on top of `0001-*`.

### Known emulation issues

* **Multi-block SD transfers with DMA lose their last sector — a QEMU
  bug.** With barebox's SDMA path (`sdhci_transfer_data_dma()`), every
  128-sector transfer through QEMU's uSDHC model comes back with the final
  512-byte sector stale while all other sectors are intact (found with
  `crc32 -f /dev/mmc1.kernel0 <off>+<len>` against the host image; the FIT
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
  decompression), the state partition (parsed and *written* on every boot,
  before anything is verified, and its contents pick the boot target), the
  raw environment partition (only if a policy sets
  `SCONFIG_ENVIRONMENT_LOAD`), and whatever the emulated peripherals expose.
  Note that the configuration signature covers the *hash values* of the
  images, not the image bytes; integrity of the bytes rests on the per-image
  `hash-1` checks that barebox performs after the signature check.
* Each policy is a separate build (`barebox-<policy>`); there is intentionally
  no runtime policy switch (`CMD_SCONFIG_MODIFY` is off).
* The A/B state is *not* authenticated: it has no `algo = "hmac(…)"` and the
  policies compile no keystore secret for it. Steering the bootchooser to the
  other slot by writing the state partition is therefore expected, not a
  finding — both slots are verified the same way before they are booted.
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
  configuration, run `nix build .#configs-normalized` and copy
  `result/*.sconfig` into `config/policies/`.
* barebox configuration: the same output also holds `result/defconfig`, the
  `make savedefconfig` form of `config/barebox/imx8mm-evk-qemu_defconfig`.
  It carries neither the comments nor the explicit `# … is not set` lines of
  the checked-in file, so merge rather than copy it.
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
