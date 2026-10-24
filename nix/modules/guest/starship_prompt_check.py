"""Check the ix/base starship prompt (./starship.toml) against the packaged starship, at image build time.

    python3 starship_prompt_check.py STARSHIP CONFIG

starship renders the prompt in a session with no SSH variables, the way `ix shell` starts one, from a home directory.
The first line must carry this machine's hostname right before the `~` directory, so `creative-wasp ~` in a VM of that
name. The hostname is read the way starship reads it (gethostname, cut at the first `.`, the module's default trim_at),
so a config that names a host itself, or shows the module only over SSH, fails here.
"""

from __future__ import annotations

import os
import re
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

SGR = re.compile(r"\x1b\[[0-9;]*m")
RENDER_TIMEOUT_S = 30


def render(starship: Path, config: Path) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory(prefix="starship-prompt-check-") as home:
        env = {
            "HOME": home,
            "PATH": os.environ.get("PATH", ""),
            "STARSHIP_CONFIG": str(config),
            "STARSHIP_CACHE": str(Path(home, "cache")),
            "TERM": "xterm-256color",
            "LANG": "C.UTF-8",
            "USER": "ix",
            "LOGNAME": "ix",
        }
        return subprocess.run(
            [str(starship), "prompt"],
            cwd=home,
            env=env,
            capture_output=True,
            text=True,
            timeout=RENDER_TIMEOUT_S,
            check=False,
        )


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    # Absolute: starship runs from a scratch home, where a relative config path names nothing and starship
    # silently falls back to its default config.
    starship, config = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
    host = socket.gethostname().split(".", 1)[0]
    try:
        result = render(starship, config)
    except subprocess.TimeoutExpired:
        print(f"starship_prompt_check: `starship prompt` did not finish within {RENDER_TIMEOUT_S} s", file=sys.stderr)
        return 1
    lines = SGR.sub("", result.stdout).lstrip("\n").splitlines()
    first = lines[0] if lines else ""
    if result.returncode != 0 or not host or not re.search(rf"(^| ){re.escape(host)} ~( |$)", first):
        print(f"starship_prompt_check: expected '{host} ~' on the prompt's first line, got {first!r}", file=sys.stderr)
        print(f"  starship exit {result.returncode}, stderr: {result.stderr.strip()[-500:]!r}", file=sys.stderr)
        return 1
    print(f"starship_prompt_check: {first.strip()!r} names host {host!r} before the directory")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
