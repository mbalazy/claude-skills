# rig-config.sh - shared by rig-check.sh and android-rig-check.sh (sourced, never run).
#
# Two things a first run trips over before any device is involved, said precisely:
#   - why the app id did not come out of .simulator-verify/config.md (no file, no line,
#     the template's placeholder still there, no value in backticks) - one message for
#     all four used to send a new user looking for a line that was right in front of them;
#   - which file the marker goes into, and when there is none, what kind of app this is
#     (an Expo Router app has no entry file in the repo at all).
# A config that works today never reaches the messages: they run only when the value
# came out empty. Values are read the way the scripts always read them - the first
# backticked token on a `- **key**: ...` line - and nothing here is cached.
#
# Why lib/ and not scripts/: see lib/_pillow.py (pm executor doctor treats every file in
# scripts/ as a tool the playbook has to explain).

RC_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# rc_config_problem <config file> <key> <flag> - one sentence: why <key> gave no value.
rc_config_problem() {
  local file="$1" key="$2" flag="$3" line
  if [ ! -f "$file" ]; then
    echo "no config: $file does not exist (and the main worktree has none either) - copy $RC_SKILL_DIR/references/config-template.md there and fill its '$key' line, or pass $flag"
    return
  fi
  line="$(grep -m1 -i -- "$key" "$file" || true)"
  if [ -z "$line" ]; then
    echo "no '$key' line in $file - add one (- **$key**: \`com.example.app\`), or pass $flag"
  elif printf '%s' "$line" | grep -q '`<'; then
    echo "the '$key' line in $file is still the template's placeholder - put the app's id there in backticks (- **$key**: \`com.example.app\`), or pass $flag"
  else
    echo "the '$key' line in $file has no id in backticks - write it as - **$key**: \`com.example.app\` - or pass $flag"
  fi
}

# rc_config_entry <config file> - the `- **entry**:` line's backticked path, if any.
# Matched strictly by its prose shape, so no other line that says "entry" counts.
rc_config_entry() {
  [ -f "$1" ] || return 0
  grep -m1 -E '^[[:space:]]*-[[:space:]]+\*\*entry\*\*:' "$1" 2>/dev/null \
    | grep -oE '`[A-Za-z0-9._/@-]+`' | head -1 | tr -d '`'
}

# rc_package_main <repo> - package.json's "main", if any.
rc_package_main() {
  [ -f "$1/package.json" ] || return 0
  python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("main") or "")' "$1/package.json" 2>/dev/null || true
}

# rc_entry_problem <repo> <entry tried> <flag> - one sentence: no entry file to mark.
rc_entry_problem() {
  local repo="$1" tried="$2" flag="$3" main layout="" l
  main="$(rc_package_main "$repo")"
  if [ -n "$main" ] && [ ! -f "$repo/$main" ] && [[ "$main" == expo-router* ]]; then
    for l in app/_layout.tsx app/_layout.js src/app/_layout.tsx src/app/_layout.js; do
      [ -f "$repo/$l" ] && { layout="$l"; break; }
    done
    echo "entry file not found: $repo/$tried, and package.json main is '$main' - a module, not a file in this repo: an Expo Router app. Mark its root layout instead: pass $flag ${layout:-app/_layout.tsx}, or put it in the config (- **entry**: \`${layout:-app/_layout.tsx}\`)"
  elif [ -n "$main" ] && [ ! -f "$repo/$main" ]; then
    echo "entry file not found: $repo/$tried, and package.json main ('$main') is not a file in this repo - pass $flag <the file the app's bundle starts from>, or put it in the config (- **entry**: \`path\`)"
  else
    echo "entry file not found: $repo/$tried (pass $flag, or put it in the config: - **entry**: \`path\`)"
  fi
}
