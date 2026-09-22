#!/usr/bin/env python3
"""state.py - the ONLY way a shift edits the sections of its state file.

usage: state.py <state-file> append     <Section> <text...>
       state.py <state-file> set-queue  <task-id> <new line...>
       state.py <state-file> set-header <key> <value...>
       state.py <state-file> sections

  append      adds "- <text>" as the LAST line of "## <Section>" (before the
              next "## " heading). Refused for "## Log" - that one is note.sh's.
  set-queue   replaces, inside "## Queue", the ONE line that starts with
              "<task-id> ·". Exit 1 on 0 or on more than 1 match; the search
              never leaves that section and is never a regex over the file.
  set-header  replaces the "<key>: ..." line of the header. The header is
              everything before the first section, and templates/state.md puts
              those keys (project/runtime/flags/window/budget/env/rig) under
              the "## Status:" heading - so that block counts as header too.
              Exit 1 on 0 or more than 1 match.
  sections    prints every section with its line count - run it after an
              append to see that the line landed where you meant.

A section name matches exactly, or as an unambiguous case-insensitive prefix
("Status" finds "## Status: closed ..."). Every command prints
"<op> -> <section> (<n> lines)"; a missing section or key exits 1 with a
message naming what was looked for.

Why this exists (solo journal 20260910-f33c): a sed/re.sub over the whole
state file overwrote the Queue section while aiming at one line. Section
edits go through here, the Log goes through note.sh, and nothing else writes
to the file.
"""
import os
import sys
import tempfile

USAGE = __doc__.split("\n\n")[1].strip()


def die(msg):
    print(f"state.py: {msg}", file=sys.stderr)
    sys.exit(1)


def usage(msg):
    print(f"state.py: {msg}\n\n{USAGE}", file=sys.stderr)
    sys.exit(2)


def read_lines(path):
    if not os.path.isfile(path):
        die(f"no state file: {path}")
    with open(path, encoding="utf-8") as f:
        return f.read().splitlines()


def write_lines(path, lines):
    """Replace the file atomically - a half-written state file is worse than none."""
    d = os.path.dirname(os.path.abspath(path)) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".state-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def is_heading(line):
    return line.startswith("## ")


def heading_name(line):
    return line[3:].strip()


def sections_of(lines):
    """[(name, heading_index, start, end)] - start..end is the body, end exclusive."""
    out = []
    for i, line in enumerate(lines):
        if not is_heading(line):
            continue
        end = len(lines)
        for j in range(i + 1, len(lines)):
            if is_heading(lines[j]):
                end = j
                break
        out.append((heading_name(line), i, i + 1, end))
    return out


def body_count(lines, start, end):
    return sum(1 for line in lines[start:end] if line.strip())


def find_section(lines, name):
    secs = sections_of(lines)
    if not secs:
        die(f"no sections in the file (no line starts with '## ')")
    exact = [s for s in secs if s[0] == name]
    if len(exact) == 1:
        return exact[0]
    if len(exact) > 1:
        die(f"section '{name}' appears {len(exact)} times - fix the file first")
    pref = [s for s in secs if s[0].lower().startswith(name.lower())]
    if len(pref) == 1:
        return pref[0]
    if len(pref) > 1:
        die(f"section '{name}' is ambiguous: {', '.join(s[0] for s in pref)}")
    die(f"no section '{name}' - the file has: {', '.join(s[0] for s in secs)}")


def line_body(line):
    """The line without its list marker, for matching."""
    s = line.strip()
    return s[2:].strip() if s.startswith("- ") else s


def cmd_append(path, argv):
    if len(argv) < 2:
        usage("append needs <Section> <text...>")
    name, text = argv[0], " ".join(argv[1:]).strip()
    if not text:
        usage("append needs a non-empty text")
    lines = read_lines(path)
    sec_name, _, start, end = find_section(lines, name)
    if sec_name.lower() == "log" or sec_name.lower().startswith("log"):
        die("the Log is append-only through scripts/note.sh - it stamps the time "
            "(and the epoch for task-start); state.py never writes to it")
    at = end
    while at > start and not lines[at - 1].strip():
        at -= 1
    lines.insert(at, f"- {text}")
    write_lines(path, lines)
    print(f"append -> {sec_name} ({body_count(lines, start, end + 1)} lines)")


def cmd_set_queue(path, argv):
    if len(argv) < 2:
        usage("set-queue needs <task-id> <new line...>")
    task_id, new = argv[0], " ".join(argv[1:]).strip()
    if not new:
        usage("set-queue needs a non-empty line")
    lines = read_lines(path)
    sec_name, _, start, end = find_section(lines, "Queue")
    hits = [i for i in range(start, end) if line_body(lines[i]).startswith(f"{task_id} ·")]
    if not hits:
        die(f"no line starting with '{task_id} ·' in ## {sec_name} - nothing written")
    if len(hits) > 1:
        die(f"{len(hits)} lines start with '{task_id} ·' in ## {sec_name} "
            f"(lines {', '.join(str(i + 1) for i in hits)}) - nothing written")
    i = hits[0]
    prefix = "- " if lines[i].strip().startswith("- ") else ""
    indent = lines[i][:len(lines[i]) - len(lines[i].lstrip())]
    lines[i] = f"{indent}{prefix}{new}"
    write_lines(path, lines)
    print(f"set-queue -> {sec_name} ({body_count(lines, start, end)} lines)")


def header_end(lines):
    """Where the header stops.

    Everything before the first section heading - except that
    templates/state.md carries the key lines under "## Status: <state>", so
    that heading belongs to the header and the first real section is the one
    after it.
    """
    for i, line in enumerate(lines):
        if is_heading(line) and not heading_name(line).lower().startswith("status"):
            return i
    return len(lines)


def cmd_set_header(path, argv):
    if len(argv) < 2:
        usage("set-header needs <key> <value...>")
    key, value = argv[0].rstrip(":"), " ".join(argv[1:]).strip()
    if not value:
        usage("set-header needs a non-empty value")
    lines = read_lines(path)
    end = header_end(lines)
    hits = [i for i in range(end) if lines[i].startswith(f"{key}:")]
    if not hits:
        keys = [line.split(":", 1)[0] for line in lines[:end] if ":" in line and not line.startswith("#")]
        die(f"no header line '{key}:' - the header has: {', '.join(keys) or '(nothing)'}")
    if len(hits) > 1:
        die(f"{len(hits)} header lines start with '{key}:' (lines "
            f"{', '.join(str(i + 1) for i in hits)}) - nothing written")
    lines[hits[0]] = f"{key}: {value}"
    write_lines(path, lines)
    print(f"set-header -> header ({body_count(lines, 0, end)} lines)")


def cmd_sections(path, argv):
    if argv:
        usage("sections takes no arguments")
    lines = read_lines(path)
    secs = sections_of(lines)
    if not secs:
        die("no sections in the file (no line starts with '## ')")
    head = header_end(lines)
    print(f"header ({body_count(lines, 0, head)} lines)")
    for name, at, start, end in secs:
        if at < head:
            continue  # the Status block is part of the header, not a section
        print(f"## {name} ({body_count(lines, start, end)} lines)")


def main(argv):
    if len(argv) < 2:
        usage("need <state-file> <command>")
    path, command, rest = argv[0], argv[1], argv[2:]
    handlers = {"append": cmd_append, "set-queue": cmd_set_queue,
                "set-header": cmd_set_header, "sections": cmd_sections}
    if command not in handlers:
        usage(f"unknown command: {command}")
    handlers[command](path, rest)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
