"""Check the ix/base btop defaults (./btop.conf) against the packaged btop, at image build time.

    python3 btop_conf_check.py BTOP CONF

btop runs in a pty whose fake terminal answers its OSC 11 background query with a light, then a dark color. What
btop paints is the evidence: the theme's main_fg names the theme theme_mode "Auto" picked, its main_bg must be absent
(theme_background = False), and no braille cell may appear (graph_symbol = "block"). A renamed option or a theme the
package no longer ships fails here: btop would otherwise fall back to its Default theme without a word.
"""

from __future__ import annotations

import fcntl
import os
import pty
import select
import shutil
import signal
import struct
import sys
import tempfile
import termios
import time
from dataclasses import dataclass
from pathlib import Path

OSC11_QUERY = b"\x1b]11;?\x07"
DA1_QUERY = b"\x1b[c"
DA1_REPLY = b"\x1b[?62;22c"
# Sandboxed builders can be slow to start btop; each run ends as soon as its evidence is in.
START_DEADLINE_S = 30.0
# btop redraws its graphs on every update (update_ms, 2000 ms by default): wait for one past the first frame.
GRAPH_REDRAW_S = 3.0
EXIT_DEADLINE_S = 10.0
COLS, ROWS = 120, 40


@dataclass(frozen=True)
class Case:
    terminal: str
    theme: str
    # The background the fake terminal reports, as an OSC 11 reply body.
    background: bytes
    # The SGR sequences btop writes for the theme's main_fg and main_bg in truecolor.
    main_fg: bytes
    main_bg: bytes


CASES = (
    Case("light", "gruvbox_light", b"rgb:fbfb/f1f1/c7c7", b"\x1b[38;2;60;56;54m", b"\x1b[48;2;251;241;199m"),
    Case("dark", "gruvbox_dark_v2", b"rgb:2828/2828/2828", b"\x1b[38;2;235;219;178m", b"\x1b[48;2;40;40;40m"),
)


@dataclass(frozen=True)
class Run:
    output: bytes
    queried: bool
    status: int | None
    log: str


def read_ready(fd: int, timeout: float) -> bytes:
    ready, _, _ = select.select([fd], [], [], max(timeout, 0.0))
    if not ready:
        return b""
    try:
        return os.read(fd, 65536)
    except OSError:
        # EIO: btop exited and closed the pty.
        return b""


def run_btop(btop: Path, conf: Path, case: Case) -> Run:
    with tempfile.TemporaryDirectory(prefix="btop-conf-check-") as home:
        config_home = Path(home, "config")
        state_home = Path(home, "state")
        (config_home / "btop").mkdir(parents=True)
        shutil.copyfile(conf, config_home / "btop" / "btop.conf")
        env = {
            "HOME": home,
            "XDG_CONFIG_HOME": str(config_home),
            "XDG_STATE_HOME": str(state_home),
            "TERM": "xterm-256color",
            "LANG": "C.UTF-8",
        }
        pid, fd = pty.fork()
        if pid == 0:
            fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
            os.execve(btop, [str(btop), "--force-utf"], env)

        output = b""
        queried = answered_da1 = False
        start = time.monotonic()
        painted_at: float | None = None
        while time.monotonic() - start < START_DEADLINE_S:
            output += read_ready(fd, 0.1)
            if not queried and OSC11_QUERY in output:
                queried = True
                os.write(fd, b"\x1b]11;" + case.background + b"\x1b\\")
            if not answered_da1 and DA1_QUERY in output:
                answered_da1 = True
                os.write(fd, DA1_REPLY)
            if painted_at is None and case.main_fg in output:
                painted_at = time.monotonic()
            if painted_at is not None and time.monotonic() - painted_at > GRAPH_REDRAW_S:
                break

        os.write(fd, b"q")
        status: int | None = None
        exit_by = time.monotonic() + EXIT_DEADLINE_S
        while status is None and time.monotonic() < exit_by:
            output += read_ready(fd, 0.1)
            done, wait_status = os.waitpid(pid, os.WNOHANG)
            if done:
                status = os.waitstatus_to_exitcode(wait_status)
        if status is None:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        os.close(fd)
        log_file = state_home / "btop.log"
        log = log_file.read_text(errors="replace") if log_file.exists() else ""
        return Run(output, queried, status, log)


def failures(case: Case, run: Run) -> list[str]:
    found: list[str] = []
    if not run.queried:
        found.append('btop never sent the OSC 11 query, so theme_mode is not "Auto"')
    if case.main_fg not in run.output:
        found.append(f"btop did not paint {case.theme}'s main_fg, so it chose another theme")
    if case.main_bg in run.output:
        found.append(f"btop painted {case.theme}'s main_bg, so theme_background is not False")
    braille = sorted({ch for ch in run.output.decode("utf-8", errors="replace") if "\u2800" <= ch <= "\u28ff"})
    if braille:
        found.append(f'btop drew braille cells {"".join(braille[:8])!r}, so graph_symbol is not "block"')
    if run.status != 0:
        found.append(f"btop did not exit 0 after 'q' (status {run.status})")
    return found


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    btop, conf = Path(sys.argv[1]), Path(sys.argv[2])
    failed = False
    for case in CASES:
        run = run_btop(btop, conf, case)
        problems = failures(case, run)
        if problems:
            failed = True
            print(f"btop_conf_check: {case.terminal} terminal, expected {case.theme}:", file=sys.stderr)
            for problem in problems:
                print(f"  {problem}", file=sys.stderr)
            if run.log:
                print("  btop.log tail:", *run.log.splitlines()[-10:], sep="\n    ", file=sys.stderr)
        else:
            print(f"btop_conf_check: {case.terminal} terminal -> {case.theme}, no theme background, block graphs")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
