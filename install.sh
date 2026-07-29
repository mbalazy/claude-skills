#!/bin/sh
# Wire this toolkit's skills into Claude Code.
#
#   ./install.sh                        # user-wide only (~/.claude/skills)
#   ./install.sh --project /path/repo   # user-wide + link into one repo
#
# Skills are linked, never copied: after a `git pull` here, every linked
# location has the new version immediately.
#
# Nothing is ever overwritten. A target that already exists as a real file or
# directory is reported and skipped - deal with it by hand and re-run.

set -eu

REPO=$(cd "$(dirname "$0")" && pwd)
SKILLS="$REPO/skills"
PROJECT=""

# Skills that must ALSO be linked inside a project repo, because a tool other
# than Claude Code looks them up by project path. `pm executor doctor` resolves
# handoff.runtime_skill only under <repo>/.claude/skills, so simulator-verify
# has to be visible there or the acceptance contract reports it missing.
PROJECT_SCOPED="simulator-verify"

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="${2:?--project needs a path}"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# link <source-dir> <target-path>
link() {
  src="$1"; dst="$2"
  if [ -L "$dst" ]; then
    current=$(readlink "$dst")
    if [ "$current" = "$src" ]; then
      echo "  ok       $dst (already linked)"
    else
      echo "  SKIP     $dst - is a link to something else:"
      echo "           $current"
    fi
    return 0
  fi
  if [ -e "$dst" ]; then
    echo "  SKIP     $dst - already exists as a real file/directory."
    echo "           Move or delete it yourself, then re-run. Nothing was touched."
    return 0
  fi
  mkdir -p "$(dirname "$dst")"
  ln -s "$src" "$dst"
  echo "  linked   $dst"
}

echo "toolkit: $REPO"
echo
echo "user-wide (~/.claude/skills):"
for dir in "$SKILLS"/*/; do
  name=$(basename "$dir")
  link "$SKILLS/$name" "$HOME/.claude/skills/$name"
done

if [ -n "$PROJECT" ]; then
  if [ ! -d "$PROJECT" ]; then
    echo >&2
    echo "error: --project path is not a directory: $PROJECT" >&2
    exit 1
  fi
  PROJECT=$(cd "$PROJECT" && pwd)
  echo
  echo "project ($PROJECT):"
  for name in $PROJECT_SCOPED; do
    if [ ! -d "$SKILLS/$name" ]; then
      echo "  SKIP     $name - not in this toolkit"
      continue
    fi
    link "$SKILLS/$name" "$PROJECT/.claude/skills/$name"
  done

  # Keep the link out of `git status` without editing the shared .gitignore.
  exclude="$PROJECT/.git/info/exclude"
  if [ -d "$PROJECT/.git" ] && ! grep -qxF '.claude/skills/' "$exclude" 2>/dev/null; then
    mkdir -p "$PROJECT/.git/info"
    printf '.claude/skills/\n' >> "$exclude"
    echo "  excluded .claude/skills/ from git status (.git/info/exclude)"
  fi
fi

cat <<'EOF'

Next: each skill reads its own per-repo config directory and will offer to
create it from a template on first run.

  simulator-verify -> <repo>/.simulator-verify/config.md
  figma-pp         -> <repo>/.figma-pp/config.md

Both directories hold real account data. Keep them out of git.
EOF
