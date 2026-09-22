"""Make Pillow importable, or explain exactly how to fix it. Import me first.

Why this exists: the two measuring scripts are the reason this skill can settle a
visual claim with a number, and they were silently broken on the machine they
were written on. Homebrew moved `python3` from 3.11 to 3.14, Pillow stayed behind
in 3.11, and `#!/usr/bin/env python3` faithfully picked the new one. The failure
is an ImportError in the middle of a verification - the worst possible moment,
and one that reads like a bug in the script rather than in the environment.

`pip install pillow` is not the fix either: a Homebrew Python refuses it under
PEP 668 (externally-managed-environment). So the dependency gets its own venv,
outside any repo, shared by every project that links this toolkit.

Order: use PIL if it is already importable; else re-exec into the toolkit venv;
else build that venv (announced on stderr, never silently) and re-exec into it;
else fail with the exact command to run by hand.

Why `lib/` and not `scripts/`: this is a private module, not a tool anybody
reaches for, and `pm executor doctor` treats everything under a runtime skill's
`scripts/` as a tool the playbook has to explain. It warned about this file the
moment it landed there, correctly.
"""

import os
import subprocess
import sys

VENV = os.environ.get(
    "CLAUDE_SKILLS_VENV",
    os.path.expanduser("~/.local/share/claude-skills/venv"),
)
VENV_PY = os.path.join(VENV, "bin", "python3")


def _have_pillow(python):
    try:
        subprocess.run(
            [python, "-c", "import PIL"],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return True
    except (OSError, subprocess.CalledProcessError):
        return False


def _reexec(python):
    # execv keeps argv, so the re-run does the work the caller asked for. It also
    # re-imports this module, where PIL now imports cleanly and nothing happens.
    os.execv(python, [python] + sys.argv)


def _build_venv():
    say = lambda m: print(f"[_pillow] {m}", file=sys.stderr)
    uv = None
    for candidate in ("uv", os.path.expanduser("~/.local/bin/uv")):
        try:
            subprocess.run(
                [candidate, "--version"],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            uv = candidate
            break
        except (OSError, subprocess.CalledProcessError):
            continue

    say(f"Pillow missing; creating a venv for it at {VENV} (one time)")
    os.makedirs(os.path.dirname(VENV), exist_ok=True)
    try:
        if uv:
            subprocess.run([uv, "venv", VENV], check=True, stderr=subprocess.STDOUT)
            subprocess.run(
                [uv, "pip", "install", "--python", VENV_PY, "pillow"],
                check=True,
                stderr=subprocess.STDOUT,
            )
        else:
            subprocess.run([sys.executable, "-m", "venv", VENV], check=True)
            subprocess.run([VENV_PY, "-m", "pip", "install", "-q", "pillow"], check=True)
    except (OSError, subprocess.CalledProcessError) as e:
        say(f"could not create it automatically: {e}")
        return False
    say("done")
    return True


def _fail():
    print(
        "This script needs Pillow, and it is not importable.\n"
        "\n"
        "Create the shared venv once:\n"
        f"    uv venv {VENV} && uv pip install --python {VENV_PY} pillow\n"
        "  (no uv? )\n"
        f"    python3 -m venv {VENV} && {VENV_PY} -m pip install pillow\n"
        "\n"
        "Then re-run this script normally - it finds that venv on its own.\n"
        "Do NOT `pip install` into a Homebrew Python: PEP 668 blocks it, and\n"
        "--break-system-packages is not worth it for one image library.\n"
        "Override the location with CLAUDE_SKILLS_VENV.",
        file=sys.stderr,
    )
    sys.exit(2)


def ensure():
    try:
        import PIL  # noqa: F401

        return
    except ImportError:
        pass

    if os.path.exists(VENV_PY) and _have_pillow(VENV_PY):
        _reexec(VENV_PY)

    if _build_venv() and _have_pillow(VENV_PY):
        _reexec(VENV_PY)

    _fail()


ensure()
