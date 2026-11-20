#!/bin/bash
# check-leaks.sh - stop work data from reaching this PUBLIC repository.
#
#   scripts/check-leaks.sh              # staged changes (what the pre-commit hook runs)
#   scripts/check-leaks.sh --all        # every tracked file in the working tree
#   scripts/check-leaks.sh --message F  # a commit message file (what the commit-msg hook runs)
#   scripts/check-leaks.sh --stdin      # any text on stdin
#
# Two sources of patterns:
#   1. A denylist that lives OUTSIDE the repo, because the names it holds are exactly what
#      must never be committed: ${CLAUDE_SKILLS_DENYLIST:-~/.config/claude-skills/denylist.txt},
#      one Perl regex per line, matched case-insensitively; blank lines and lines starting
#      with # are ignored. Missing file = a warning, not a failure (a fresh clone still works).
#   2. Generic shapes checked here: bundle ids outside com.example, home directories,
#      physical-device udids, Apple team ids, e-mail addresses, tracker / chat / design-tool
#      URLs, LAN addresses and common secret formats (plus `gitleaks`, when installed).
#
# Known fictional values that look real (fake udids in tests, the WebSocket GUID) are
# listed in .leak-allow at the repo root, one literal per line; a match equal to one of
# them passes. Add a value there only when it is fictional.
#
# Exit: 0 clean, 1 something matched (each hit printed as file:line: kind: match), 2 usage.
# Never bypass a hit with --no-verify: fix the text (use a placeholder) or, for a fictional
# value, add it to .leak-allow.

set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "check-leaks: not inside a git repository" >&2; exit 2; }
DENY="${CLAUDE_SKILLS_DENYLIST:-$HOME/.config/claude-skills/denylist.txt}"
ALLOW="$ROOT/.leak-allow"
MODE="staged"; MSG=""
case "${1:-}" in
  "") ;;
  --all) MODE="all" ;;
  --stdin) MODE="stdin" ;;
  --message) MODE="message"; MSG="${2:?--message needs a file}" ;;
  -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "check-leaks: unknown argument: $1" >&2; exit 2 ;;
esac

if [ ! -f "$DENY" ]; then
  echo "check-leaks: WARNING - no denylist at $DENY; only generic patterns are checked." >&2
  DENY=/dev/null
fi

# Produce "<file>\t<line>\t<text>" for every line to check.
lines() {
  case "$MODE" in
    staged)
      git -C "$ROOT" diff --cached -U0 --no-color --no-ext-diff --diff-filter=ACMR | perl -ne '
        if (/^\+\+\+ b\/(.*)$/) { $f = $1; next }
        if (/^@@ -\S+ \+(\d+)/) { $n = $1; next }
        if (/^\+(.*)$/ && defined $f) { print "$f\t$n\t$1\n"; $n++ }' ;;
    all)
      git -C "$ROOT" grep -I -n -e '' -- . | perl -ne 'if (/^([^:]+):(\d+):(.*)$/) { print "$1\t$2\t$3\n" }' ;;
    message)
      grep -v '^#' "$MSG" | perl -ne 'print "commit-message\t$.\t$_"' ;;
    stdin)
      perl -ne 'print "stdin\t$.\t$_"' ;;
  esac
}

HITS="$(lines | perl -e '
  my ($deny, $allow) = @ARGV; @ARGV = ();
  my @deny;
  if (open my $d, "<", $deny) { while (<$d>) { chomp; s/\r$//; next if /^\s*(#|$)/; push @deny, qr/$_/i } }
  my %allow;
  if (open my $a, "<", $allow) { while (<$a>) { chomp; next if /^\s*(#|$)/; $allow{$_} = 1 } }
  my @generic = (
    [ "bundle-id",  qr/\b(?:com|org|io|pl|net|de|ch|co|uk|dev)\.(?!example\b|apple\b|facebook\b)[a-z0-9-]+\.[a-z][A-Za-z0-9-]*(?:\.[A-Za-z0-9-]+)*\b/ ],
    [ "home-path",  qr{/Users/(?!(?:alice|bob|dev|x|you|me|USER|username|name|runner|Shared)\b)(?!<)[A-Za-z0-9._-]+} ],
    [ "device-udid", qr/\b0000[0-9]{4}-[0-9A-F]{16}\b/ ],
    [ "uuid",       qr/\b[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\b/ ],
    [ "team-id",    qr/(?:DEVELOPMENT_TEAM|team[ _-]?id|--team)\W{0,4}[A-Z0-9]{10}\b/i ],
    [ "email",      qr/[A-Za-z0-9._%+-]+@(?!example\.(?:com|org)\b)[A-Za-z0-9-]+\.[A-Za-z0-9.-]*[a-z]{2,}/ ],
    [ "tracker-url", qr{(?:[a-z0-9-]+\.atlassian\.net|linear\.app/[a-z0-9-]+/|[a-z0-9-]+\.slack\.com|figma\.com/(?:file|design|proto)/|notion\.so/[A-Za-z0-9]|dev\.azure\.com/[A-Za-z0-9]|gitlab\.com/[A-Za-z0-9])}i ],
    [ "lan-ip",     qr/\b(?:10\.\d{1,3}|192\.168|172\.(?:1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}\b/ ],
    [ "secret",     qr/(?:AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{30,}|sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{40,}|xox[abprs]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|https:\/\/[0-9a-f]{32}@[a-z0-9.-]*sentry\.io)/ ],
  );
  while (<STDIN>) {
    chomp; my ($f, $n, $t) = split /\t/, $_, 3; next unless defined $t;
    next if $f eq ".leak-allow";
    for my $re (@deny) { while ($t =~ /($re)/g) { print "$f:$n: denylist: $1\n" unless $allow{$1} } }
    for my $g (@generic) { my ($k, $re) = @$g; while ($t =~ /($re)/g) { print "$f:$n: $k: $1\n" unless $allow{$1} } }
  }' "$DENY" "$ALLOW")"

RC=0
if [ -n "$HITS" ]; then
  printf '%s\n' "$HITS"
  RC=1
fi
if [ "$MODE" = staged ] && command -v gitleaks >/dev/null 2>&1; then
  if ! gitleaks protect --staged --no-banner --redact -v --source "$ROOT" >/tmp/check-leaks-gitleaks.$$ 2>&1; then
    cat /tmp/check-leaks-gitleaks.$$; RC=1
  fi
  rm -f /tmp/check-leaks-gitleaks.$$
fi
if [ "$RC" -ne 0 ]; then
  echo "check-leaks: work data in a public repo - replace it with a placeholder (com.example.app, MyApp, PROJ-123, <DEVICE_NAME>), or list a FICTIONAL value in .leak-allow." >&2
fi
exit "$RC"
