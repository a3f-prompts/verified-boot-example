# SPDX-License-Identifier: MIT
"""End-to-end tests for the reference bootchain.

Run with:  pytest --lg-env labgrid/imx8mm-evk-qemu.yaml tests
(or `nix run .#test-<policy>`), with $LG_IMAGES pointing at the images.
"""

import os
import re
import struct
import zlib

import pytest

# type GUID of the partition barebox stores its state in, see
# BAREBOX_STATE_PARTITION_GUID in include/state.h
STATE_PARTITION_GUID = "4778ed65-bf42-45fa-9c5b-287a1dc4aab1"


def gpt_partitions(path):
    """{ name: (byte offset, byte size, type GUID) } of a raw GPT image."""
    with open(path, "rb") as f:
        f.seek(512)
        header = f.read(92)
        assert header[:8] == b"EFI PART", header[:8]
        entry_lba, count, entry_size = struct.unpack_from("<QII", header, 72)
        f.seek(entry_lba * 512)
        entries = f.read(count * entry_size)

    def guid(raw):
        a, b, c, d, e = struct.unpack("<IHH2s6s", raw)
        return f"{a:08x}-{b:04x}-{c:04x}-{d.hex()}-{e.hex()}"

    parts = {}
    for i in range(count):
        entry = entries[i * entry_size : (i + 1) * entry_size]
        first, last = struct.unpack_from("<QQ", entry, 32)
        name = entry[56:128].decode("utf-16-le").rstrip("\0")
        if name:
            parts[name] = (first * 512, (last - first + 1) * 512, guid(entry[:16]))
    return parts


@pytest.fixture(scope="session")
def partitions():
    return gpt_partitions(os.path.join(os.environ["LG_IMAGES"], "disk.img"))


@pytest.fixture
def pristine(strategy):
    """For tests that write to the state: the SD card is opened in snapshot
    mode, so power cycling before and after is enough to keep the state
    changes from leaking into other tests."""
    strategy.transition("off")
    yield strategy
    strategy.transition("off")


def test_barebox_comes_up(strategy):
    strategy.transition("booted")
    assert "barebox" in strategy.log["banner"]


def test_active_policy(strategy, policy, interactive):
    if not interactive:
        pytest.skip(f"policy {policy} does not allow console input")
    strategy.transition("barebox")
    out = strategy.barebox.run_check("sconfig")
    assert any(policy in line for line in out), out


def test_fit_key_compiled_in(strategy, interactive):
    if not interactive:
        pytest.skip("no console input")
    strategy.transition("barebox")
    out = strategy.barebox.run_check("keys")
    joined = "\n".join(out)
    assert "RING: fit" in joined, joined
    assert "HINT: dev" in joined, joined


def test_disk_layout(partitions):
    """The card holds the state and one kernel partition per A/B slot."""
    assert set(partitions) == {"state", "kernel0", "kernel1"}
    assert partitions["state"][2] == STATE_PARTITION_GUID


@pytest.mark.parametrize("partition", ["kernel0", "kernel1"])
def test_sd_card_is_read_intact(strategy, interactive, partitions, partition):
    """Multi-block reads through QEMU's uSDHC model must not corrupt data;
    the FIT hash checks depend on it."""
    if not interactive:
        pytest.skip("no console input")
    offset, _, _ = partitions[partition]
    length = 1 << 20
    strategy.transition("barebox")
    out = strategy.barebox.run_check(f"crc32 -f /dev/mmc1.{partition} 0+{length:#x}")
    m = re.search(r"==> 0x([0-9a-f]{8})", " ".join(out))
    assert m, out
    with open(os.path.join(os.environ["LG_IMAGES"], "disk.img"), "rb") as f:
        f.seek(offset)
        expected = zlib.crc32(f.read(length)) & 0xFFFFFFFF
    assert int(m.group(1), 16) == expected


def test_state_is_registered(strategy, interactive):
    """The state node resolves to the GPT partition with the state type GUID
    (barebox looks it up on the device the "backend" phandle points at) and
    the variable set has the layout and defaults from the device tree."""
    if not interactive:
        pytest.skip("no console input")
    strategy.transition("barebox")
    out = "\n".join(strategy.barebox.run_check("state"))
    assert re.search(r"^state\s+\(backend: raw, path: /dev/mmc1\.", out, re.M), out

    out = "\n".join(strategy.barebox.run_check("devinfo state"))
    for var, value in [
        ("bootstate.system0.priority", 20),
        ("bootstate.system0.remaining_attempts", 3),
        ("bootstate.system1.priority", 10),
        ("bootstate.system1.remaining_attempts", 3),
    ]:
        assert f"{var}: {value} " in out, out


def test_bootchooser_prefers_the_first_slot(strategy, interactive):
    if not interactive:
        pytest.skip("no console input")
    strategy.transition("barebox")
    out = "\n".join(strategy.barebox.run_check("bootchooser -i"))
    good, _, disabled = out.partition("Disabled targets:")
    assert good.index("system0") < good.index("system1"), out
    assert "none" in disabled, out


def test_attempts_are_counted_down_in_the_state(pristine, interactive):
    """A boot attempt decrements the counter of the chosen target and writes
    it to the card; `state -l` reads it back from there."""
    if not interactive:
        pytest.skip("no console input")
    pristine.transition("barebox")
    out = "\n".join(pristine.barebox.run_check("boot -v -d bootchooser"))
    assert "selected target 'system0'" in out, out

    pristine.barebox.run_check("state -l")
    out = "\n".join(pristine.barebox.run_check("devinfo state"))
    assert "bootstate.system0.remaining_attempts: 2 " in out, out
    assert "bootstate.last_chosen: 1 " in out, out

    # ... and the raw partition really is where it ended up
    out = "\n".join(pristine.barebox.run_check("md -l -s /dev/mmc1.state 0+0x10"))
    assert "9d3a2b17" in out, out


def test_boots_signed_linux(strategy):
    strategy.transition("linux")
    assert "signature OK" in strategy.log["verify"]
    assert "hash BAD" not in strategy.log["verify"]
    assert re.search(r"Linux version 6\.\d+", strategy.log["linux-banner"])


def test_boots_the_first_slot_by_default(strategy):
    strategy.transition("linux")
    assert strategy.booted_slot == "system0"
    # the FIT descriptions differ per slot, so this shows which of the two
    # kernel partitions was actually read
    assert strategy.booted_fit_slot == "system0"
    assert "bootchooser.active=system0" in strategy.linux_run("cat /proc/cmdline")


def test_linux_is_arm64(strategy):
    strategy.transition("linux")
    assert strategy.linux_run("uname -m") == "aarch64"


def test_linux_sees_imx8mm_evk_dt(strategy):
    strategy.transition("linux")
    model = strategy.linux_run("cat /proc/device-tree/model")
    assert "i.MX8MM" in model, model


def test_linux_sees_the_state(strategy):
    """barebox copies the state description into the device tree it hands to
    Linux, so that userspace (barebox-state from dt-utils) finds the same
    variable set at the same place."""
    strategy.transition("linux")
    assert "raw" in strategy.linux_run("cat /proc/device-tree/state/backend-type")
    assert "direct" in strategy.linux_run(
        "cat /proc/device-tree/state/backend-storage-type"
    )


def test_priority_selects_the_other_slot(pristine, interactive):
    """Raising system1's priority in the state boots the second slot."""
    if not interactive:
        pytest.skip("no console input")
    pristine.transition("barebox")
    pristine.barebox.run_check("bootchooser -p 30 system1")
    pristine.transition("linux")
    assert pristine.booted_slot == "system1"
    assert pristine.booted_fit_slot == "system1"
    assert "bootchooser.active=system1" in pristine.linux_run("cat /proc/cmdline")
