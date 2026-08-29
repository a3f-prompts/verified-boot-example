# SPDX-License-Identifier: MIT
"""labgrid strategy that walks the reference bootchain.

States, in order:

  off      QEMU not running
  booted   barebox banner seen (PBL has started barebox proper)
  barebox  interactive barebox shell (needs a policy with console input)
  linux    barebox verified and booted the FIT; busybox initramfs shell reached

The console output that led to each state is kept in `log` so tests can
make assertions about what happened along the way.
"""

import enum
import re

import attr

from labgrid import step, target_factory
from labgrid.strategy import Strategy, StrategyError

BAREBOX_BANNER = r"barebox 20\d\d\.\d\d\.\d[^\r\n]*"
SIGNATURE_OK = r"Key\s+[0-9a-f]+ \([^)]*\) -> signature OK"
INITRAMFS_REACHED = r"initramfs reached"


class Status(enum.Enum):
    unknown = 0
    off = 1
    booted = 2
    barebox = 3
    linux = 4


@target_factory.reg_driver
@attr.s(eq=False)
class BootchainStrategy(Strategy):
    bindings = {
        "power": "PowerProtocol",
        "console": "ConsoleProtocol",
        "barebox": "BareboxDriver",
    }

    status = attr.ib(default=Status.unknown)
    log = attr.ib(default=attr.Factory(dict))

    def _expect(self, pattern, timeout, what):
        try:
            _, before, match, _ = self.console.expect(pattern, timeout=timeout)
        except Exception as e:  # pexpect.TIMEOUT/EOF wrapped by labgrid
            raise StrategyError(f"waiting for {what} ({pattern!r}) failed: {e}") from e
        text = before.decode("utf-8", "replace") if isinstance(before, bytes) else before
        matched = match.group(0)
        matched = matched.decode("utf-8", "replace") if isinstance(matched, bytes) else matched
        self.log[what] = text + matched
        return matched

    @step(args=["status"])
    def transition(self, status, *, step):
        if not isinstance(status, Status):
            status = Status[status]
        if status == Status.unknown:
            raise StrategyError(f"can not transition to {status}")
        if status == self.status:
            step.skip("nothing to do")
            return

        if status == Status.off:
            self.target.deactivate(self.barebox)
            self.target.deactivate(self.console)
            self.target.activate(self.power)
            self.power.off()
            self.log = {}
        elif status == Status.booted:
            self.transition(Status.off)
            self.target.activate(self.console)
            self.power.on()
            self.log["banner"] = self._expect(BAREBOX_BANNER, 60, "banner")
        elif status == Status.barebox:
            self.transition(Status.booted)
            # interrupts autoboot and waits for the prompt
            self.target.activate(self.barebox)
        elif status == Status.linux:
            if self.status in (Status.unknown, Status.off):
                self.transition(Status.booted)
            if self.status == Status.barebox:
                self.barebox.boot("")
                self.target.deactivate(self.barebox)
            # from here on the console is no longer at a barebox prompt: if
            # anything below fails, the next transition has to start over
            self.status = Status.unknown
            # nv.bootm.verbose=1 makes the autoboot path print the FIT
            # verification result just like an interactive "boot -v"
            self._expect(SIGNATURE_OK, 120, "verify")
            self._expect(r"Linux version [^\r\n]*", 120, "linux-banner")
            self._expect(INITRAMFS_REACHED, 300, "initramfs")
            # busybox ash prompt; kernel messages may follow it, so no anchor
            self._expect(r"~ # ", 60, "linux-prompt")
        else:
            raise StrategyError(f"no transition found from {self.status} to {status}")

        self.status = status

    def linux_run(self, command, timeout=30):
        """Run a command in the initramfs shell and return its output."""
        if self.status != Status.linux:
            raise StrategyError("not in linux state")
        # the marker is split in the command line so that the echoed command
        # does not match it, only the shell's output does
        self.console.sendline(f'{command}; echo "__bootchain"_done__')
        _, before, _, _ = self.console.expect(r"__bootchain_done__", timeout=timeout)
        text = before.decode("utf-8", "replace") if isinstance(before, bytes) else before
        text = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", text)  # terminal escape sequences
        # drop the echoed command line
        text = text.split("\n", 1)[1] if "\n" in text else ""
        return text.strip()
