#!/usr/bin/env bash
#
# mac-prefs.sh -- carry macOS app preferences to a new Mac without Migration Assistant.
#
#   ./mac-prefs.sh export              # on the OLD Mac: dump domains to mac-prefs-export/ next to this script
#   ./mac-prefs.sh import <dir>        # on the NEW Mac: load them back
#   ./mac-prefs.sh list                # show which domains exist on this Mac
#   ./mac-prefs.sh diff <dir>          # compare an export against this Mac
#
# Domains are read from mac-prefs-domains.conf next to this script.
#
# Some macOS settings -- Control Center and menu bar layout, Spotlight's menu
# icon, per-device keyboard mappings -- are stored per-machine in the ByHost
# domain (~/Library/Preferences/ByHost/), keyed by hardware UUID, and are only
# reachable via `defaults -currentHost`. This script checks both locations for
# every domain automatically. ByHost exports are saved as <domain>.byhost.plist
# and re-imported with -currentHost, so they land under the NEW Mac's UUID.
# Copying those files by hand would not work; importing them does.
#
# Filenames are lossy in one direction: a `/` in a domain becomes `_` in the
# export filename, and on import every `_` becomes `/` again. A domain that
# already contains `_` therefore does not survive the round trip. Export warns
# when it writes one; import such a domain by hand with `defaults import`.
#
# Import writes a rollback backup of whatever it is about to overwrite, so a
# bad import is normally one command away from being undone. The backup is
# best-effort: a domain that cannot be read is reported and left out, and the
# backup's MANIFEST.txt records that it is incomplete.
#
# Written for the stock /bin/bash 3.2 that ships with macOS -- no bash 4 features.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONF="${MACPREFS_CONF:-$SCRIPT_DIR/mac-prefs-domains.conf}"
DEFAULT_OUT="$SCRIPT_DIR/mac-prefs-export"
DEFAULT_SNAPSHOT_DIR="$HOME/vc/mac-prefs-config"

DRY_RUN=0
ASSUME_YES=0
QUIT_APPS=0
MP_TMP=""

# ---------------------------------------------------------------- output helpers

if [ -t 1 ]; then
  C_DIM=$'\033[2m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'
  C_YEL=$'\033[33m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_DIM=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLD=""; C_RST=""
fi

info() { printf '%s\n' "$*"; }
ok()   { printf '%s  ok%s  %s\n'  "$C_GRN" "$C_RST" "$*"; }
skip() { printf '%sskip%s  %s\n'  "$C_DIM" "$C_RST" "$*"; }
warn() { printf '%swarn%s  %s\n'  "$C_YEL" "$C_RST" "$*" >&2; }
die()  { printf '%sfail%s  %s\n'  "$C_RED" "$C_RST" "$*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight

require_macos() {
  [ "$(uname -s)" = "Darwin" ] || die "this script only runs on macOS (found $(uname -s))"
  command -v defaults >/dev/null 2>&1 || die "'defaults' not found in PATH"
  command -v plutil   >/dev/null 2>&1 || die "'plutil' not found in PATH"
}

# Prints one domain per line: comments stripped, blanks dropped, de-duplicated.
read_domains() {
  [ -f "$CONF" ] || die "domain list not found: $CONF"
  sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$CONF" \
    | awk 'NF && !seen[$0]++'
}

# domain_exists <domain> [byhost]
domain_exists() {
  if [ "${2:-}" = "byhost" ]; then
    defaults -currentHost read "$1" >/dev/null 2>&1
    return $?
  fi
  [ "$1" = "NSGlobalDomain" ] && return 0
  defaults read "$1" >/dev/null 2>&1
}

# do_export <domain> <outfile> [byhost]
do_export() {
  if [ "${3:-}" = "byhost" ]; then
    defaults -currentHost export "$1" "$2" 2>/dev/null
  else
    defaults export "$1" "$2" 2>/dev/null
  fi
}

# do_import <domain> <infile> [byhost]
do_import() {
  if [ "${3:-}" = "byhost" ]; then
    defaults -currentHost import "$1" "$2" 2>/dev/null
  else
    defaults import "$1" "$2" 2>/dev/null
  fi
}

# Turn an export filename into "<domain> <mode>".
# com.apple.dock.plist              -> com.apple.dock
# com.apple.controlcenter.byhost.plist -> com.apple.controlcenter byhost
file_to_domain() {
  local base; base="$(basename "$1" .plist)"
  case "$base" in
    *.byhost) printf '%s byhost\n' "$(printf '%s' "${base%.byhost}" | tr '_' '/')" ;;
    *)        printf '%s\n'        "$(printf '%s' "$base"           | tr '_' '/')" ;;
  esac
}

# domain -> application process name, for apps that must be quit before their
# prefs are rewritten. A running app flushes its in-memory copy on exit and
# will happily clobber whatever you just imported.
QUITTABLE="
com.apple.Photos:Photos
com.apple.Safari:Safari
com.apple.mail:Mail
com.apple.iCal:Calendar
com.apple.AddressBook:Contacts
com.apple.Notes:Notes
com.apple.reminders:Reminders
com.apple.Terminal:Terminal
com.apple.Preview:Preview
com.apple.TextEdit:TextEdit
com.apple.ActivityMonitor:Activity Monitor
"

# UI processes restarted after an import so the new settings take effect.
# ControlCenter owns the menu bar and Control Center layout on Big Sur and later.
RESTARTABLE="cfprefsd Finder Dock SystemUIServer ControlCenter"

# Args: domain list. Prints the names of affected apps that are running now.
running_apps_for_domains() {
  local doms=" $* "
  local line dom app
  printf '%s\n' "$QUITTABLE" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    dom="${line%%:*}"
    app="${line#*:}"
    case "$doms" in
      *" $dom "*)
        if pgrep -x "$app" >/dev/null 2>&1; then printf '%s\n' "$app"; fi
        ;;
    esac
  done
}

quit_app() {
  local app="$1" n=0
  osascript -e "tell application \"$app\" to quit" >/dev/null 2>&1 || true
  while pgrep -x "$app" >/dev/null 2>&1 && [ "$n" -lt 20 ]; do
    sleep 0.5; n=$((n + 1))
  done
  ! pgrep -x "$app" >/dev/null 2>&1
}

confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  local reply=""
  if [ -r /dev/tty ]; then
    read -r -p "$1 [y/N] " reply </dev/tty || return 1
  else
    read -r -p "$1 [y/N] " reply || return 1
  fi
  case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------- export core

MP_EXPORTED=0
MP_BYHOST=0
MP_SKIPPED=0
MP_FAILED=0

# export_into <dir> <as_xml:0|1>
# Walks the domain list, writing one plist per domain (plus a .byhost.plist
# where a ByHost half exists). With as_xml=1 the plists are converted to XML,
# which is what makes them diff cleanly in git.
export_into() {
  local dir="$1" as_xml="${2:-0}"
  local domains; domains="$(read_domains)"
  local d safe got

  MP_EXPORTED=0; MP_BYHOST=0; MP_SKIPPED=0; MP_FAILED=0

  for d in $domains; do
    safe="$(printf '%s' "$d" | tr '/' '_')"
    got=0

    # 1. the ordinary domain
    if domain_exists "$d"; then
      if [ "$DRY_RUN" -eq 1 ]; then
        ok "$d ${C_DIM}(dry run)${C_RST}"; got=1
      elif do_export "$d" "$dir/$safe.plist"; then
        [ "$as_xml" -eq 1 ] && plutil -convert xml1 "$dir/$safe.plist" >/dev/null 2>&1
        ok "$d"; got=1
      else
        warn "$d -- export failed"
        MP_FAILED=$((MP_FAILED + 1))
      fi
      [ "$got" -eq 1 ] && MP_EXPORTED=$((MP_EXPORTED + 1))
    fi

    # 2. the ByHost half, where Control Center and friends actually live
    if domain_exists "$d" byhost; then
      if [ "$DRY_RUN" -eq 1 ]; then
        ok "$d ${C_DIM}(ByHost, dry run)${C_RST}"
        MP_BYHOST=$((MP_BYHOST + 1)); got=1
      elif do_export "$d" "$dir/$safe.byhost.plist" byhost; then
        [ "$as_xml" -eq 1 ] && plutil -convert xml1 "$dir/$safe.byhost.plist" >/dev/null 2>&1
        ok "$d ${C_DIM}(ByHost)${C_RST}"
        MP_BYHOST=$((MP_BYHOST + 1)); got=1
      else
        warn "$d -- ByHost export failed"
        MP_FAILED=$((MP_FAILED + 1))
      fi
    fi

    if [ "$got" -eq 0 ]; then
      skip "$d ${C_DIM}(not set on this Mac)${C_RST}"
      MP_SKIPPED=$((MP_SKIPPED + 1))
    fi

    # `/` becomes `_` in the filename and every `_` becomes `/` again on
    # import, so a domain that already contains `_` cannot round-trip.
    if [ "$got" -eq 1 ]; then
      case "$d" in
        *_*)
          warn "$d -- name does not round-trip: import would read $safe.plist back as '$(printf '%s' "$safe" | tr '_' '/')'."
          warn "        Import this one by hand:  defaults import $d $dir/$safe.plist"
          ;;
      esac
    fi
  done
}

write_manifest() {
  local dir="$1" exported="$2" byhost="$3"
  {
    echo "macprefs_version 2"
    echo "exported_at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "source_host $(scutil --get ComputerName 2>/dev/null || hostname)"
    echo "macos_version $(sw_vers -productVersion)"
    echo "macos_build $(sw_vers -buildVersion)"
    echo "domain_count $exported"
    echo "byhost_count $byhost"
  } > "$dir/MANIFEST.txt"
}

# ---------------------------------------------------------------- export

cmd_export() {
  require_macos
  local out="${1:-$DEFAULT_OUT}"
  [ -n "$out" ] || out="$DEFAULT_OUT"

  local stamp; stamp="$(date +%Y-%m-%d-%H%M%S)"
  local dir="$out/$stamp"

  local domains; domains="$(read_domains)"
  [ -n "$domains" ] || die "no domains listed in $CONF"
  local count; count="$(printf '%s\n' "$domains" | wc -l | tr -d ' ')"

  info "${C_BLD}Exporting $count domains${C_RST} -> $dir"
  info ""

  local running; running="$(running_apps_for_domains $domains)"
  if [ -n "$running" ]; then
    warn "these apps are running; quit them for a fully current export:"
    warn "  $(printf '%s' "$running" | tr '\n' ' ')"
    info ""
  fi

  [ "$DRY_RUN" -eq 1 ] || mkdir -p "$dir"

  export_into "$dir" 0
  local exported="$MP_EXPORTED" byhost="$MP_BYHOST" skipped="$MP_SKIPPED" failed="$MP_FAILED"

  if [ "$DRY_RUN" -eq 0 ]; then
    write_manifest "$dir" "$exported" "$byhost"
    ln -sfn "$stamp" "$out/latest"
  fi

  info ""
  info "${C_BLD}$exported domains, $byhost ByHost, $skipped skipped, $failed failed${C_RST}"
  if [ "$DRY_RUN" -eq 0 ]; then
    info "Folder: $dir"
    info ""
    info "Copy that folder to the new Mac, then run:"
    info "  ./mac-prefs.sh import <folder> --quit-apps"
  fi
  # Exit non-zero on any failure: a wrapper (LaunchAgent, script) cannot
  # otherwise tell a complete export from one that wrote almost nothing.
  [ "$failed" -eq 0 ] || return 1
}

# ---------------------------------------------------------------- snapshot

# Export into a settings repo and commit the result. Deliberately does NOT
# push -- pushing is git-autosync's job, and a snapshot that fails to push
# should still be a snapshot.
#
# Target resolution: argument, then $MACPREFS_SNAPSHOT_DIR, then the default.
# Settings are written to <target>/current/, overwriting the previous state:
# git already stores the history, so timestamped folders would only duplicate
# it. Plists are converted to XML so `git log -p` reads as a changelog.
cmd_snapshot() {
  require_macos
  local target="${1:-}"
  [ -n "$target" ] || target="${MACPREFS_SNAPSHOT_DIR:-$DEFAULT_SNAPSHOT_DIR}"
  # expand a leading ~
  case "$target" in "~"/*) target="$HOME/${target#~/}" ;; esac

  [ -d "$target" ] || die "settings repo not found: $target
Clone it first, or pass the path:  $0 snapshot <path>"

  local dir="$target/current"

  info "${C_BLD}Snapshotting${C_RST} -> $dir"
  info ""

  local domains; domains="$(read_domains)"
  local running; running="$(running_apps_for_domains $domains)"
  if [ -n "$running" ]; then
    warn "running apps may not have flushed current settings to disk:"
    warn "  $(printf '%s' "$running" | tr '\n' ' ')"
    info ""
  fi

  if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p "$dir"
    # clear stale files so a domain you removed from the config disappears
    rm -f "$dir"/*.plist "$dir/MANIFEST.txt"
  fi

  export_into "$dir" 1
  local failed="$MP_FAILED"

  if [ "$DRY_RUN" -eq 1 ]; then
    info ""
    info "${C_BLD}$MP_EXPORTED domains, $MP_BYHOST ByHost, $MP_SKIPPED skipped, $failed failed ${C_DIM}(dry run)${C_RST}"
    [ "$failed" -eq 0 ] || return 1
    return 0
  fi

  write_manifest "$dir" "$MP_EXPORTED" "$MP_BYHOST"

  info ""
  info "${C_BLD}$MP_EXPORTED domains, $MP_BYHOST ByHost, $MP_SKIPPED skipped, $failed failed${C_RST}"
  [ "$failed" -eq 0 ] || warn "this snapshot is incomplete -- $failed domain(s) could not be exported"

  if [ ! -d "$target/.git" ]; then
    warn "$target is not a git repository -- files written, nothing committed"
    [ "$failed" -eq 0 ] || return 1
    return 0
  fi

  # `git add` gets its own exit status. Folded into the command substitution
  # below, a locked index or a permissions problem looks exactly like a clean
  # tree, and the freshly written plists are left uncommitted while the run
  # reports "nothing changed".
  # Staging is scoped to current/: this command owns that directory and
  # nothing else in the settings repo.
  local add_err add_rc
  add_err="$(cd "$target" && git add -A -- current 2>&1)"; add_rc=$?
  if [ "$add_rc" -ne 0 ]; then
    warn "git add failed in $target (exit $add_rc) -- settings written but NOT committed"
    [ -n "$add_err" ] && warn "  $add_err"
    return 1
  fi

  # Commit only if something actually changed. MANIFEST.txt carries a
  # timestamp that changes every run, so it cannot be the only thing staged.
  local changed
  changed="$(cd "$target" && git diff --cached --name-only -- current \
             | grep -v '^current/MANIFEST.txt$' | wc -l | tr -d ' ')"

  if [ "${changed:-0}" -eq 0 ]; then
    # Only MANIFEST.txt moved, and only because it stamps the time. Put it
    # back so the settings repo is left as it was found -- unstaging current/
    # only, so work the user had staged elsewhere stays staged.
    ( cd "$target" \
        && git reset -q -- current \
        && git checkout -- current/MANIFEST.txt 2>/dev/null ) || true
    info ""
    info "No settings changed since the last snapshot -- nothing committed."
    [ "$failed" -eq 0 ] || return 1
    return 0
  fi

  local host; host="$(scutil --get ComputerName 2>/dev/null || hostname)"
  local msg="snapshot: $changed changed on $host

$(cd "$target" && git diff --cached --name-only -- current | sed 's/^current\///' | head -30)"

  # Scoped to current/ for the same reason as the staging above.
  if ( cd "$target" && git commit -q -m "$msg" -- current ); then
    info ""
    ok "committed $changed changed file(s) in $target"
    # Tell the transport there is something to push. Without this the commit
    # waits for the interval job - up to 15 minutes - while the line above
    # implies it is on its way. The touch is harmless if git-autosync is not
    # installed: an unread file in .git.
    touch "$target/.git/autosync-push" 2>/dev/null || true
    info "${C_DIM}push happens via git-autosync${C_RST}"
  else
    warn "commit failed in $target"
    return 1
  fi

  [ "$failed" -eq 0 ] || return 1
}

# ---------------------------------------------------------------- import

cmd_import() {
  require_macos
  local dir="${1:-}"
  [ -n "$dir" ] || die "usage: $0 import <export-folder>"
  [ -d "$dir" ] || die "not a folder: $dir"
  # allow passing the parent folder -- resolve the 'latest' symlink for them
  if [ ! -f "$dir/MANIFEST.txt" ] && [ -d "$dir/latest" ]; then
    dir="$dir/latest"
  fi
  [ -f "$dir/MANIFEST.txt" ] || warn "no MANIFEST.txt in $dir -- proceeding anyway"

  if [ -f "$dir/MANIFEST.txt" ]; then
    local src_ver here_ver src_major here_major
    src_ver="$(awk '/^macos_version/{print $2}' "$dir/MANIFEST.txt")"
    here_ver="$(sw_vers -productVersion)"
    src_major="${src_ver%%.*}"; here_major="${here_ver%%.*}"
    info "${C_DIM}export from macOS $src_ver  ->  this Mac runs macOS $here_ver${C_RST}"
    if [ -n "$src_major" ] && [ "$src_major" != "$here_major" ]; then
      warn "different major macOS versions -- preferences usually survive this,"
      warn "but obsolete keys may come along. The rollback backup covers you."
    fi
    info ""
  fi

  local plists="" f
  for f in "$dir"/*.plist; do
    [ -e "$f" ] || continue
    plists="$plists$f
"
  done
  [ -n "$plists" ] || die "no .plist files found in $dir"

  # Collect plain domain names (without mode) for the running-app check.
  local doms="" line d mode
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    line="$(file_to_domain "$f")"
    doms="$doms ${line%% *}"
  done <<EOF
$plists
EOF

  local running; running="$(running_apps_for_domains $doms)"
  if [ -n "$running" ]; then
    if [ "$QUIT_APPS" -eq 1 ]; then
      local app
      while IFS= read -r app; do
        [ -n "$app" ] || continue
        if quit_app "$app"; then ok "quit $app"; else warn "could not quit $app"; fi
      done <<EOF
$running
EOF
      info ""
    else
      warn "running apps will overwrite imported prefs when they exit:"
      warn "  $(printf '%s' "$running" | tr '\n' ' ')"
      warn "quit them first, or re-run with --quit-apps"
      confirm "Continue anyway?" || die "aborted"
      info ""
    fi
  fi

  # Rollback snapshot of current state, taken before anything is touched.
  # Best-effort: a domain that cannot be read (TCC, permissions) is counted
  # and named rather than silently dropped -- the undo command below cannot
  # restore what was never saved.
  local backup="" backup_failed=0 backup_missed=""
  if [ "$DRY_RUN" -eq 0 ]; then
    backup="$HOME/.mac-prefs-rollback/$(date +%Y-%m-%d-%H%M%S)"
    mkdir -p "$backup"
    local safe
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      line="$(file_to_domain "$f")"
      d="${line%% *}"
      case "$line" in *" byhost") mode="byhost" ;; *) mode="" ;; esac
      safe="$(printf '%s' "$d" | tr '/' '_')"
      if domain_exists "$d" "$mode"; then
        if [ "$mode" = "byhost" ]; then
          do_export "$d" "$backup/$safe.byhost.plist" byhost || {
            backup_failed=$((backup_failed + 1)); backup_missed="$backup_missed $d(ByHost)"; }
        else
          do_export "$d" "$backup/$safe.plist" || {
            backup_failed=$((backup_failed + 1)); backup_missed="$backup_missed $d"; }
        fi
      fi
    done <<EOF
$plists
EOF
    printf 'macprefs_version 2\nrollback_for %s\ncreated %s\nincomplete %s\n' \
      "$dir" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$backup_failed" > "$backup/MANIFEST.txt"
    if [ "$backup_failed" -gt 0 ]; then
      printf 'not_backed_up%s\n' "$backup_missed" >> "$backup/MANIFEST.txt"
      warn "rollback backup is INCOMPLETE -- $backup_failed domain(s) could not be read:"
      warn "  ${backup_missed# }"
      warn "the undo command shown at the end will NOT restore those domains."
      info "${C_DIM}rollback backup (PARTIAL): $backup${C_RST}"
    else
      info "${C_DIM}rollback backup: $backup${C_RST}"
    fi
    info ""
  fi

  info "${C_BLD}Importing preferences${C_RST}"
  info ""

  local imported=0 failed=0 label
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    line="$(file_to_domain "$f")"
    d="${line%% *}"
    case "$line" in *" byhost") mode="byhost"; label="$d ${C_DIM}(ByHost)${C_RST}" ;;
                    *)          mode="";       label="$d" ;; esac
    if ! plutil -lint "$f" >/dev/null 2>&1; then
      warn "$d -- corrupt plist, skipping"
      failed=$((failed + 1)); continue
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      ok "$label ${C_DIM}(dry run)${C_RST}"
      imported=$((imported + 1)); continue
    fi
    if do_import "$d" "$f" "$mode"; then
      ok "$label"
      imported=$((imported + 1))
    else
      warn "$d -- import failed"
      failed=$((failed + 1))
    fi
  done <<EOF
$plists
EOF

  if [ "$DRY_RUN" -eq 0 ]; then
    local p
    for p in $RESTARTABLE; do killall "$p" >/dev/null 2>&1 || true; done
  fi

  info ""
  info "${C_BLD}$imported imported, $failed failed${C_RST}"
  if [ "$DRY_RUN" -eq 0 ]; then
    info ""
    info "Menu bar and Control Center reload with ControlCenter; log out and"
    info "back in for everything else to settle."
    if [ "$backup_failed" -gt 0 ]; then
      info "To undo (PARTIAL -- $backup_failed domain(s) were not backed up):"
      info "  ./mac-prefs.sh import \"$backup\" --yes"
    else
      info "To undo:  ./mac-prefs.sh import \"$backup\" --yes"
    fi
  fi
  # Non-zero when anything failed, so a wrapper can tell an import that
  # worked from one that imported nothing at all.
  [ "$failed" -eq 0 ] || return 1
}

# ---------------------------------------------------------------- list / diff

cmd_list() {
  require_macos
  local domains; domains="$(read_domains)"
  local d present=0 byhost=0 absent=0
  for d in $domains; do
    local hit=0
    if domain_exists "$d"; then ok "$d"; present=$((present + 1)); hit=1; fi
    if domain_exists "$d" byhost; then
      ok "$d ${C_DIM}(ByHost)${C_RST}"; byhost=$((byhost + 1)); hit=1
    fi
    [ "$hit" -eq 0 ] && { skip "$d"; absent=$((absent + 1)); }
  done
  info ""
  info "${C_BLD}$present present, $byhost ByHost, $absent not set${C_RST}"
}

cmd_diff() {
  require_macos
  local dir="${1:-}"
  [ -n "$dir" ] && [ -d "$dir" ] || die "usage: $0 diff <export-folder>"
  if [ ! -f "$dir/MANIFEST.txt" ] && [ -d "$dir/latest" ]; then dir="$dir/latest"; fi

  MP_TMP="$(mktemp -d)"
  trap 'rm -rf "${MP_TMP:-}"' EXIT
  local tmp="$MP_TMP"

  local f line d mode label same=0 differ=0 missing=0
  for f in "$dir"/*.plist; do
    [ -e "$f" ] || continue
    line="$(file_to_domain "$f")"
    d="${line%% *}"
    case "$line" in *" byhost") mode="byhost"; label="$d ${C_DIM}(ByHost)${C_RST}" ;;
                    *)          mode="";       label="$d" ;; esac
    if ! domain_exists "$d" "$mode"; then
      skip "$label ${C_DIM}(not set here)${C_RST}"; missing=$((missing + 1)); continue
    fi
    do_export "$d" "$tmp/current.plist" "$mode" || continue
    # normalise both to XML so binary-vs-xml encoding is not reported as a change
    plutil -convert xml1 "$tmp/current.plist" -o "$tmp/a.xml" 2>/dev/null || continue
    plutil -convert xml1 "$f" -o "$tmp/b.xml" 2>/dev/null || continue
    if diff -q "$tmp/a.xml" "$tmp/b.xml" >/dev/null 2>&1; then
      ok "$label ${C_DIM}(identical)${C_RST}"; same=$((same + 1))
    else
      warn "$label differs"
      diff "$tmp/a.xml" "$tmp/b.xml" | head -20 | sed 's/^/      /'
      differ=$((differ + 1))
    fi
  done
  info ""
  info "${C_BLD}$same identical, $differ differ, $missing not set here${C_RST}"
}

# ---------------------------------------------------------------- arg parsing

usage() {
  cat <<'EOF'
mac-prefs.sh -- carry macOS app preferences to a new Mac

USAGE
  ./mac-prefs.sh export [folder]     dump domains
                                    (default: mac-prefs-export/ next to this script)
  ./mac-prefs.sh import <folder>     load them onto this Mac
  ./mac-prefs.sh snapshot [repo]     dump into a settings repo and commit
  ./mac-prefs.sh list                show which domains exist here
  ./mac-prefs.sh diff <folder>       compare an export against this Mac

OPTIONS
  -n, --dry-run      show what would happen, change nothing
  -y, --yes          skip confirmation prompts
  -q, --quit-apps    quit affected apps automatically before importing
  -c, --conf FILE    use a different domain list
  -h, --help         this text

TYPICAL USE
  old Mac:   ./mac-prefs.sh export
             # copy the mac-prefs-export folder to the new Mac (AirDrop, USB, ...)
  new Mac:   ./mac-prefs.sh import mac-prefs-export/latest --quit-apps

SNAPSHOT
  `snapshot` keeps a private settings repo up to date. It writes into
  <repo>/current/ -- overwriting the previous state, because git already
  stores the history -- converts the plists to XML so `git log -p` reads as
  a changelog, and commits only when something actually changed. It never
  pushes; that is git-autosync's job.

  Target: the argument, else $MACPREFS_SNAPSHOT_DIR, else ~/vc/mac-prefs-config

  Restore on a new Mac:
    ./mac-prefs.sh import ~/vc/mac-prefs-config/current --quit-apps

  The settings repo holds account details and machine-specific paths.
  Keep it private.

BYHOST
  Control Center and menu bar layout, Spotlight's menu icon and per-device
  keyboard mappings live in the per-machine ByHost domain, keyed by hardware
  UUID. Both halves of every domain are exported; ByHost ones are saved as
  <domain>.byhost.plist and re-imported with -currentHost so they land under
  the new Mac's UUID. Copying those files by hand does not work.

NOTES
  Quit Photos, Safari and Mail before exporting -- a running app holds its
  preferences in memory and the on-disk copy may lag behind what you see.

  Import saves a rollback copy to ~/.mac-prefs-rollback/<timestamp> first.
  Undo with:  ./mac-prefs.sh import ~/.mac-prefs-rollback/<timestamp> --yes
  The copy is best-effort: a domain that cannot be read is named in a warning
  and left out, and the copy's MANIFEST.txt then says `incomplete <n>` and
  lists the domains it does not cover.

  Not every setting lives in preferences. Photos album sort order, for one,
  is partly held in the photo library database -- expect to set that by hand.

  This moves settings, not data. Photos, Mail and Safari content comes from
  iCloud or your own backup; this script only carries the knobs.
EOF
}

main() {
  local cmd="" arg1=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -n|--dry-run)   DRY_RUN=1 ;;
      -y|--yes)       ASSUME_YES=1 ;;
      -q|--quit-apps) QUIT_APPS=1 ;;
      -c|--conf)      shift; CONF="${1:-}" ;;
      -h|--help)      usage; exit 0 ;;
      -*)             die "unknown option: $1" ;;
      *)              if [ -z "$cmd" ]; then cmd="$1"
                      elif [ -z "$arg1" ]; then arg1="$1"; fi ;;
    esac
    shift
  done

  case "$cmd" in
    export)   cmd_export "$arg1" ;;
    import)   cmd_import "$arg1" ;;
    snapshot) cmd_snapshot "$arg1" ;;
    list)     cmd_list ;;
    diff)     cmd_diff "$arg1" ;;
    "")       usage; exit 1 ;;
    *)        die "unknown command: $cmd" ;;
  esac
}

main "$@"
