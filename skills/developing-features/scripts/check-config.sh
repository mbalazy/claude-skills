#!/usr/bin/env bash
# check-config.sh - gather evidence about .developing-features/config.md.
#
#   check-config.sh [repo-path]     # defaults to the enclosing git repo
#
# The config is trusted blind by every phase of the skill and nothing else
# re-checks it, so the no-feature mode exists to re-derive it. This script does
# the mechanical half of that: it runs the derivations and prints measured next
# to claimed. The judging stays with whoever asked, because in that mode there
# is always a reader.
#
# ## Why it mostly does not adjudicate
#
# The first version failed the run on any path or workflow filename in the
# config that was not on disk. Against a real config it produced five failures
# and all five were false: four were workflow names the config mentions
# precisely to say they NO LONGER EXIST. It punished the config for documenting
# dead names honestly, and no regex fixes that - "this file is here" and "this
# file is gone" are both legitimate things for a config to state, in the same
# words.
#
# One false alarm is how a checker gets switched off for good, so:
#
#   FAIL  - hard, affects the exit code. ONLY assertions in a field-value
#           position (the first line of a `- **field**: value` bullet), which is
#           where the config states what IS, and only where the answer is a
#           binary fact: a path, the base branch, a package.json script. Prose,
#           sub-bullets and continuation lines never fail the run - that is
#           where a config explains, qualifies and warns.
#   INFO  - printed for a reader, never affects the exit code. Citations with
#           the line they currently point at, workflow presence, the real commit
#           shapes, the pre-commit hook. Most of the value is here.
#
# Exit: 0 = no hard failures (INFO may still need reading), 1 = a FAIL, 2 = cannot run.

set -uo pipefail

REPO="${1:-}"
if [ -z "$REPO" ]; then
  REPO=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "not in a git repo and no path given" >&2; exit 2; }
fi
REPO=$(cd "$REPO" 2>/dev/null && pwd) || { echo "no such directory: ${1:-}" >&2; exit 2; }
CONFIG="$REPO/.developing-features/config.md"
[ -f "$CONFIG" ] || { echo "no config at $CONFIG" >&2; exit 2; }
cd "$REPO" || exit 2

TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT

fails=0
infos=0
bold=$(tput bold 2>/dev/null || true); off=$(tput sgr0 2>/dev/null || true)
section() { printf '\n%s%s%s\n' "$bold" "$1" "$off"; }
ok()   { printf '  [ ok ] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; fails=$((fails+1)); }
info() { printf '  [info] %s\n' "$1"; infos=$((infos+1)); }
skip() { printf '  [ -- ] %s\n' "$1"; }

# --- the hard-check surface -------------------------------------------------
# The first line of a `- **field**: value` bullet. Sub-bullets (indented) and
# continuation lines are excluded by the leading-dash-at-column-1 anchor.
# A field whose value NEGATES is excluded too: "no such file" is a claim about
# absence, and checking it as if it claimed presence is exactly the bug this
# script was rewritten to remove.
field_values() {
  grep -E '^- \*\*[^*]+\*\*:?' "$CONFIG" \
    | sed -E 's/^- \*\*[^*]+\*\*:?[[:space:]]*//' \
    | grep -viE '^\*\*no|^no[[:space:],.]|does not exist|do not exist|no longer|none of which'
}

# Backticked tokens that look like a plain repo-relative path: no globs, no
# {placeholders}, no URLs, and an extension.
#
# Two exclusions, both learned by running this against a real config:
#   - it must contain a `/`. A config naming a sibling-file convention writes
#     the suffixes bare (`.container.tsx`, `.perf.tsx`); those are fragments of
#     a filename, not files, and there is nothing on disk to find.
#   - never a workflow. `pr-checks.yml` is real but lives under
#     .github/workflows/, so a repo-root lookup misses it. Workflows have their
#     own section below, where presence is reported and never failed.
paths_in() {
  grep -oE '`[^`]+`' | tr -d '`' \
    | grep -E '^\.?[A-Za-z0-9_./-]+\.[A-Za-z0-9]+$' \
    | grep -E '/' \
    | grep -vE '[*{}<>]|^https?:|\.ya?ml$' | sort -u
}

section "Paths stated as present (hard)"
field_values | paths_in > "$TMP/paths"
if [ ! -s "$TMP/paths" ]; then
  info "the config states no plain paths in field-value position"
else
  while read -r p; do
    [ -n "$p" ] || continue
    if [ -e "$REPO/$p" ]; then
      ok "$p"
    elif [ -e "$REPO/.claude/skills/$p" ] || [ -e "$REPO/.agents/skills/$p" ]; then
      # A skill referred to by its own short name rather than the full path.
      # Real, but ambiguous - worth saying, not worth failing over.
      info "$p resolves only as a skill-relative path - write it in full"
    else
      fail "path does not exist: $p"
    fi
  done < "$TMP/paths"
fi

section "package.json scripts stated as present (hard)"
if [ -f package.json ]; then
  have=$(node -e 'try{console.log(Object.keys(require("./package.json").scripts||{}).join("\n"))}catch(e){}' 2>/dev/null)
  field_values | grep -oE '\b(yarn|npm run) [a-z][a-z0-9:_-]*' | awk '{print $NF}' | sort -u > "$TMP/scripts"
  while read -r s; do
    [ -n "$s" ] || continue
    if printf '%s\n' "$have" | grep -qx "$s"; then ok "script $s"
    else fail "config names a script package.json does not have: $s"; fi
  done < "$TMP/scripts"
else
  skip "no package.json"
fi

section "Base branch (hard)"
stated=$(grep -E '^- \*\*base branch\*\*' "$CONFIG" | grep -oE '`[^`]+`' | head -1 | tr -d '`')
measured=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
if [ -z "$measured" ]; then
  info "origin/HEAD is not set locally - run: git remote set-head origin -a (config says '${stated:-?}')"
elif [ -z "$stated" ]; then
  fail "the config does not state a base branch; origin/HEAD says '$measured'"
elif [ "$measured" = "$stated" ]; then
  ok "config says '$stated', origin/HEAD agrees"
else
  fail "config says '$stated', origin/HEAD says '$measured'"
fi

# --- everything below is evidence, never a verdict ---------------------------

section "Citations: does the cited line still say it? (info)"
# Line numbers drift whenever the cited document is edited, and a citation that
# has slid onto another paragraph is worse than none - it still looks like
# evidence. Printing the line is cheaper than any rule about it.
#
# The fallback directory for a bare `NAME.md:12` comes from the config's own
# architecture-document field, so this works in a repo that keeps its guide
# somewhere other than .claude/.
archdoc=$(grep -E '^- \*\*architecture document\*\*' "$CONFIG" | grep -oE '`[^`]+`' | head -1 | tr -d '`')
archdir=$(dirname "${archdoc:-./x}")
grep -oE '`?[A-Za-z0-9_./-]+\.md:[0-9]+' "$CONFIG" | tr -d '`' | sort -u > "$TMP/cites"
if [ ! -s "$TMP/cites" ]; then
  info "the config cites no file:line - nothing can rot, and nothing is sourced"
else
  while read -r cite; do
    f="${cite%:*}"; n="${cite##*:}"
    [ -f "$REPO/$f" ] || f="$archdir/$f"
    if [ ! -f "$REPO/$f" ]; then info "$cite -> no such file"; continue; fi
    total=$(wc -l < "$REPO/$f" | tr -d ' ')
    if [ "$n" -gt "$total" ]; then info "$cite -> PAST END OF FILE ($total lines) - the citation has rotted"; continue; fi
    info "$cite | $(sed -n "${n}p" "$REPO/$f" | cut -c1-96)"
  done < "$TMP/cites"
fi

section "CI workflows the config names (info)"
grep -oE '`[^`]+`' "$CONFIG" | tr -d '`' | grep -E '\.ya?ml$' | sort -u > "$TMP/wf"
if [ ! -s "$TMP/wf" ]; then
  skip "the config names no workflows"
else
  while read -r w; do
    if [ -e "$REPO/.github/workflows/$(basename "$w")" ] || [ -e "$REPO/$w" ]; then
      info "present: $w"
    else
      info "ABSENT:  $w  (fine if the config names it to say it is gone - check which)"
    fi
  done < "$TMP/wf"
fi

section "Commit shapes actually in use (info)"
base="${measured:-${stated:-}}"
if [ -n "$base" ] && git rev-parse --verify -q "origin/$base" >/dev/null; then
  git log "origin/$base" --format=%s -n 200 \
    | grep -oE '^([a-z]+(\([^)]+\))?: |[A-Z]+-[0-9]+: |[a-z]+\([A-Z]+-[0-9]+\): )' \
    | sed -E 's/\([^)]+\)/(scope)/; s/[A-Z]+-[0-9]+/KEY/' \
    | sort | uniq -c | sort -rn | head -6 > "$TMP/shapes"
  if [ -s "$TMP/shapes" ]; then
    info "last 200 on origin/$base, by prefix shape:"
    sed 's/^/           /' "$TMP/shapes"
  else
    info "last 200 on origin/$base carry no recognisable prefix shape"
  fi
else
  skip "no origin/$base to read commits from"
fi

section "Pre-commit hooks (info)"
if [ -f .husky/pre-commit ]; then
  info "$(tr '\n' ';' < .husky/pre-commit | sed 's/;$//')"
else
  skip "no .husky/pre-commit"
fi

section "Not checkable here"
skip "PR body policy, squash policy - prose, read them against the cited lines above"
skip "ticket board state names - needs the ticket API, not a shell"
skip "whether the validation command is green - run it"

printf '\n%d hard failure(s), %d line(s) of evidence to read.\n' "$fails" "$infos"
[ "$fails" -gt 0 ] && exit 1
exit 0
