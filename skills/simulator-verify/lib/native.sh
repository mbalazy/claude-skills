# native.sh - shared by native-build.sh, native-rig-check.sh and the two RN rig checks
# (sourced, never run).
#
# A native app (Swift / Objective-C, Kotlin / Java) has no Metro and no JS bundle to mark:
# the code IS the installed binary. So the native rig check proves the binary by CONTENT,
# never by a date:
#   - the tree fingerprint: HEAD's tree + `git diff HEAD` + every untracked, not-ignored
#     file. Two checkouts with the same content have the same fingerprint, a branch switch
#     or one edited line changes it. A date cannot do this: comparing the binary's mtime
#     with the last commit's date reads OK after a switch to a branch whose newest commit
#     is older than the build (2026-11-23, found while onboarding a native app).
#   - the artifact hash: sha256 over every file of the built .app (relative path + content)
#     or of the .apk. `simctl install` and `adb install` copy the artifact byte for byte
#     (checked 2026-11-23: an iOS 26.4 simulator, an API 36 emulator), so the installed copy
#     hashes the same as the one on disk.
# native-build.sh records both in a per-checkout file inside the checkout's git dir (never
# committed, never shared between worktrees); native-rig-check.sh recomputes both and
# compares.
#
# Config lines it reads from <repo>/.simulator-verify/config.md:
#   - **app type**: `native`
#   - **build**: `<command, run from the repo root>`
#   - **artifact**: `<the built .app or .apk, repo-relative or absolute>`
# plus the `bundle id` / `android package` lines the RN rig checks read.

# nv_config_for <repo> - the config file the rig checks would read: the checkout's own,
# else the main worktree's (`.simulator-verify/` is normally git-ignored, so a fresh
# worktree has none; both are checkouts of one project).
nv_config_for() {
  local repo="$1" common
  if [ -f "$repo/.simulator-verify/config.md" ]; then
    echo "$repo/.simulator-verify/config.md"; return
  fi
  common="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [ -n "$common" ] && [ -f "$(dirname "$common")/.simulator-verify/config.md" ]; then
    echo "$(dirname "$common")/.simulator-verify/config.md"; return
  fi
  echo "$repo/.simulator-verify/config.md"
}

# nv_config_line <config> <key> - the text between the first and the last backtick of the
# `- **<key>**:` line (a build command keeps its spaces and quotes). Empty when absent.
nv_config_line() {
  [ -f "$1" ] || return 0
  grep -m1 -iE "^[[:space:]]*-[[:space:]]+\*\*$2\*\*:" "$1" 2>/dev/null \
    | sed -nE 's/^[^`]*`(.*)`[^`]*$/\1/p' | head -1
}

# nv_app_type <config> - `native`, or whatever else the line says (lowercased), or empty.
nv_app_type() { nv_config_line "$1" "app type" | tr '[:upper:]' '[:lower:]'; }

# nv_app_id <config> <ios|android> - the bundle id (iOS) or the package (Android: the
# `android package` line first, as android-rig-check.sh).
nv_app_id() {
  local f="$1" line=""
  [ -f "$f" ] || return 0
  if [ "$2" = android ]; then
    line="$(grep -m1 -i 'android package' "$f" || true)"
  fi
  [ -n "$line" ] || line="$(grep -m1 -i 'bundle id' "$f" || true)"
  printf '%s\n' "$line" | grep -oE '`[A-Za-z0-9._-]+`' | head -1 | tr -d '`'
}

# nv_abs <repo> <path> - a config path made absolute (`~/` and repo-relative both work).
nv_abs() {
  case "$2" in
    \~/*) echo "$HOME/${2#\~/}" ;;
    /*)    echo "$2" ;;
    *)     echo "$1/$2" ;;
  esac
}

# nv_platform_of <artifact path> - ios for a .app, android for an .apk, else empty.
nv_platform_of() {
  case "$1" in
    *.app|*.app/) echo ios ;;
    *.apk)        echo android ;;
  esac
}

# nv_fingerprint <repo> - sha256 of the tree's CONTENT as it is now (see the header).
# Ignored files are outside it on purpose (build output, caches); a build input that is
# git-ignored (an ignored Pods/, local.properties) is not seen - rebuild by hand after
# changing one.
nv_fingerprint() {
  local repo="$1" head paths
  head="$(git -C "$repo" rev-parse -q --verify 'HEAD^{tree}' 2>/dev/null || echo none)"
  {
    echo "tree $head"
    if [ "$head" != none ]; then
      git -C "$repo" -c core.quotePath=false diff --binary --no-ext-diff --no-textconv \
        --no-color --no-renames HEAD -- 2>/dev/null
    fi
    paths="$(cd "$repo" && git -c core.quotePath=false ls-files --others --exclude-standard 2>/dev/null | LC_ALL=C sort)"
    if [ -n "$paths" ]; then
      echo "untracked"
      paste -d ' ' <(cd "$repo" && printf '%s\n' "$paths" | git hash-object --stdin-paths 2>/dev/null) \
                   <(printf '%s\n' "$paths")
    fi
  } | shasum -a 256 | cut -d' ' -f1
}

# nv_hash_local <path> - sha256 of a local .app directory (every file and symlink by
# relative path) or of a single file.
nv_hash_local() {
  local p="$1"
  if [ -d "$p" ]; then
    (
      cd "$p" || exit 1
      find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256
      find . -type l -print0 | LC_ALL=C sort -z | while IFS= read -r -d '' l; do
        printf 'link %s -> %s\n' "$l" "$(readlink "$l")"
      done
    ) | shasum -a 256 | cut -d' ' -f1
  elif [ -f "$p" ]; then
    shasum -a 256 "$p" | cut -d' ' -f1
  fi
}

# --- the build record ----------------------------------------------------------------------
# One `key=value` file per checkout, in the checkout's own git dir (a linked worktree has
# its own), so two worktrees sharing a DerivedData or an emulator never read each other's.

nv_record_path() {
  local gd
  gd="$(git -C "$1" rev-parse --path-format=absolute --git-dir 2>/dev/null)" || return 1
  echo "$gd/simulator-verify-native"
}

# nv_record_get <record file> <key>
nv_record_get() {
  [ -f "$1" ] || return 0
  grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2-
}

# nv_record_write <record file> key=value... - replaces the whole record atomically.
nv_record_write() {
  local f="$1" tmp; shift
  tmp="$(mktemp "$f.XXXXXX")" || return 1
  printf '%s\n' "$@" > "$tmp" && mv "$tmp" "$f"
}

nv_fmt_epoch() { date -r "$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "?"; }

# --- dispatch from the RN rig checks ----------------------------------------------------------
# nv_dispatch <ios|android> <native script> "$@" - called first thing by rig-check.sh and
# android-rig-check.sh: when the config of the repo under test says `app type: native`, the
# Metro marker cannot work (there is no entry file and no Metro), so the native check runs
# instead with the same arguments. Same verdict lines, same exit codes - a caller that
# requires `RIG OK` from rig-check.sh needs no change.
nv_dispatch() {
  local platform="$1" script="$2" repo="" a prev="" cfg
  shift 2
  for a in "$@"; do
    [ "$prev" = --repo ] && repo="$a"
    prev="$a"
  done
  [ -n "$repo" ] || repo="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$repo" ] && [ -d "$repo" ] || return 0
  repo="$(cd "$repo" && pwd -P)"
  cfg="$(nv_config_for "$repo")"
  [ "$(nv_app_type "$cfg")" = native ] || return 0
  exec bash "$script" --platform "$platform" "$@"
}
