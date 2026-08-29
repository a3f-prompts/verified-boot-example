# SPDX-License-Identifier: MIT
"""End-to-end tests for the reference bootchain.

Run with:  pytest --lg-env labgrid/imx8mm-evk-qemu.yaml tests
(or `nix run .#test-<policy>`), with $LG_IMAGES pointing at the images.
"""

import os
import re
import zlib

import pytest


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


def test_sd_card_is_read_intact(strategy, interactive):
    """Multi-block reads through QEMU's uSDHC model must not corrupt data;
    the FIT hash checks depend on it."""
    if not interactive:
        pytest.skip("no console input")
    strategy.transition("barebox")
    out = strategy.barebox.run_check("crc32 -f /dev/mmc1.kernel 0+0x100000")
    m = re.search(r"==> 0x([0-9a-f]{8})", " ".join(out))
    assert m, out
    with open(os.path.join(os.environ["LG_IMAGES"], "disk.img"), "rb") as f:
        f.seek(1 << 20)  # the "kernel" partition starts at 1 MiB
        expected = zlib.crc32(f.read(1 << 20)) & 0xFFFFFFFF
    assert int(m.group(1), 16) == expected


def test_boots_signed_linux(strategy):
    strategy.transition("linux")
    assert "signature OK" in strategy.log["verify"]
    assert "hash BAD" not in strategy.log["verify"]
    assert re.search(r"Linux version 6\.\d+", strategy.log["linux-banner"])


def test_linux_is_arm64(strategy):
    strategy.transition("linux")
    assert strategy.linux_run("uname -m") == "aarch64"


def test_linux_sees_imx8mm_evk_dt(strategy):
    strategy.transition("linux")
    model = strategy.linux_run("cat /proc/device-tree/model")
    assert "i.MX8MM" in model, model
