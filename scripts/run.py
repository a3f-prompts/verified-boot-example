#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Start the reference bootchain in QEMU and attach an interactive console.

This is a slightly extended version of labgrid's examples/qemu-run.py. It
uses the same labgrid environment file as the test suite, so what you see
interactively is exactly what the tests exercise.

Leave the console with Ctrl-\\ followed by q (microcom).
"""

import argparse
import logging
import os
import shlex
import sys

from labgrid import Environment
from labgrid.logging import StepLogger, basicConfig


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "-c",
        "--config",
        default=os.environ.get("LG_ENV"),
        help="labgrid environment file (default: $LG_ENV)",
    )
    parser.add_argument(
        "-s",
        "--state",
        default=os.environ.get("LG_STATE"),
        help="strategy state to reach before attaching, e.g. stage2, barebox or linux "
        "(default: just start QEMU)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="print the QEMU command line (without labgrid's console chardev) and exit",
    )
    parser.add_argument("-v", "--verbose", action="count", default=0)
    args = parser.parse_args()

    if not args.config:
        parser.error("no environment file given (-c or $LG_ENV)")
    if "LG_IMAGES" not in os.environ:
        parser.error("$LG_IMAGES is not set; use `nix run` or point it at an images-<policy> output")

    basicConfig(level=logging.DEBUG if args.verbose else logging.INFO)
    StepLogger.start()

    env = Environment(config_file=args.config)
    target = env.get_target()
    qemu = target.get_driver("QEMUDriver", activate=False)

    if args.dry_run:
        print(shlex.join(qemu.get_qemu_base_args()))
        return 0

    if args.state:
        strategy = target.get_driver("Strategy")
        strategy.transition(args.state)
    else:
        target.activate(qemu)
        qemu.on()

    qemu.interact()
    return 0


if __name__ == "__main__":
    sys.exit(main())
