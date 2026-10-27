#!/usr/bin/env bash
#
# Runs mac-prefs.sh against stand-ins for the macOS tools (tests/bin) and
# checks what snapshot, import and export write, keep and delete. Needs no
# Mac: bash 3.2 or later and git.
#
#   tests/run.sh          run every test
#   tests/run.sh import   run the tests whose name contains "import"

set -u

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$TESTS_DIR/../mac-prefs.sh"
FILTER="${1:-}"
FAILURES=0
RUN=0

# ---------------------------------------------------------------- fixture

# Each test starts from a fresh folder $T: a home, a store of settings the
# stand-in defaults reads ($FAKE_PREFS), a domain list, and a settings repo
# cloned from a bare remote, so a snapshot can commit and push.
setup() {
  T="$(mktemp -d "${TMPDIR:-/tmp}/mac-prefs-test.XXXXXX")"
  mkdir -p "$T/home" "$T/prefs" "$T/tmp"
  export HOME="$T/home" FAKE_PREFS="$T/prefs" NO_COLOR=1
  # The git config of the machine running the tests (signing, hooks) stays
  # out of the test repositories.
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$T/gitconfig"
  git config --file "$T/gitconfig" user.name "Test"
  git config --file "$T/gitconfig" user.email "test@example.com"
  git config --file "$T/gitconfig" init.defaultBranch main
  printf 'com.example.alpha\ncom.example.beta\ncom.example.gamma\n' >"$T/conf"
  git init -q --bare "$T/remote.git"
  git clone -q "$T/remote.git" "$T/settings" 2>/dev/null
  (cd "$T/settings" && echo "settings" >README.md && git add README.md &&
    git commit -q -m "chore: start" && git push -q origin HEAD:main &&
    git branch -q -u origin/main) >/dev/null 2>&1
}

teardown() { rm -rf "$T"; }

# set_pref <domain> <value> [byhost]: the setting the stand-in Mac holds.
set_pref() {
  local suffix=.plist
  [ "${3:-}" = byhost ] && suffix=.byhost.plist
  echo "<plist>$1 $2</plist>" >"$FAKE_PREFS/$1$suffix"
}

# The stand-ins come first on PATH; TMPDIR keeps the tool's scratch
# folders inside $T.
mac_prefs() {
  PATH="$TESTS_DIR/bin:$PATH" TMPDIR="$T/tmp" \
    bash "$TOOL" -c "$T/conf" "$@" >"$T/out" 2>&1
}

commits() { git -C "$T/settings" rev-list --count HEAD; }
pushed() { git -C "$T/remote.git" rev-list --count main; }

# ---------------------------------------------------------------- assertions

fail() {
  echo "    $*"
  FAILED=1
}

expect_status() {
  [ "$STATUS" -eq "$1" ] || fail "exit status $STATUS, expected $1"
}
expect_file() { [ -f "$1" ] || fail "missing: ${1#"$T"/}"; }
expect_no_file() { [ ! -e "$1" ] || fail "should not exist: ${1#"$T"/}"; }
expect_content() {
  [ "$(cat "$1" 2>/dev/null)" = "$2" ] || fail "${1#"$T"/} holds '$(cat "$1" 2>/dev/null)', expected '$2'"
}
expect_output() {
  grep -qF -- "$1" "$T/out" || fail "output lacks: $1"
}
expect_equal() {
  [ "$1" = "$2" ] || fail "$3: got '$1', expected '$2'"
}

# ---------------------------------------------------------------- tests

test_snapshot_writes_commits_and_pushes_every_readable_domain() {
  set_pref com.example.alpha 1
  set_pref com.example.beta 1
  set_pref com.example.gamma 1
  mac_prefs snapshot "$T/settings"
  STATUS=$?
  expect_status 0
  expect_content "$T/settings/current/com.example.alpha.plist" "<plist>com.example.alpha 1</plist>"
  expect_file "$T/settings/current/com.example.beta.plist"
  expect_file "$T/settings/current/com.example.gamma.plist"
  expect_file "$T/settings/current/MANIFEST.txt"
  expect_equal "$(commits)" 2 "commits in the settings repo"
  expect_equal "$(pushed)" 2 "commits on the remote"
}

test_snapshot_keeps_the_file_of_a_domain_it_cannot_read() {
  set_pref com.example.alpha 1
  set_pref com.example.beta 1
  set_pref com.example.gamma 1
  mac_prefs snapshot "$T/settings"
  rm "$FAKE_PREFS/com.example.beta.plist"
  set_pref com.example.alpha 2
  mac_prefs snapshot "$T/settings"
  STATUS=$?
  expect_status 0
  expect_content "$T/settings/current/com.example.alpha.plist" "<plist>com.example.alpha 2</plist>"
  expect_content "$T/settings/current/com.example.beta.plist" "<plist>com.example.beta 1</plist>"
  expect_output "kept 1 file(s) from the last snapshot"
  grep -qx "kept_unreadable com.example.beta.plist" "$T/settings/current/MANIFEST.txt" ||
    fail "MANIFEST.txt does not record com.example.beta.plist as kept_unreadable"
}

test_snapshot_deletes_the_file_of_a_domain_removed_from_the_list() {
  set_pref com.example.alpha 1
  set_pref com.example.beta 1
  set_pref com.example.gamma 1
  mac_prefs snapshot "$T/settings"
  printf 'com.example.alpha\ncom.example.gamma\n' >"$T/conf"
  mac_prefs snapshot "$T/settings"
  STATUS=$?
  expect_status 0
  expect_no_file "$T/settings/current/com.example.beta.plist"
  expect_file "$T/settings/current/com.example.alpha.plist"
  expect_equal "$(commits)" 3 "commits in the settings repo"
}

test_snapshot_writes_the_byhost_half_as_its_own_file() {
  set_pref com.example.alpha 1
  set_pref com.example.alpha 7 byhost
  mac_prefs snapshot "$T/settings"
  STATUS=$?
  expect_status 0
  expect_content "$T/settings/current/com.example.alpha.byhost.plist" "<plist>com.example.alpha 7</plist>"
  expect_file "$T/settings/current/com.example.alpha.plist"
  expect_output "1 ByHost"
}

test_snapshot_commits_nothing_when_no_setting_changed() {
  set_pref com.example.alpha 1
  mac_prefs snapshot "$T/settings"
  mac_prefs snapshot "$T/settings"
  STATUS=$?
  expect_status 0
  expect_output "No settings changed since the last snapshot"
  expect_equal "$(commits)" 2 "commits in the settings repo"
  [ -z "$(git -C "$T/settings" status --porcelain)" ] || fail "the settings repo is left with changes"
}

# An export folder as snapshot and export write it: one file per domain
# and half, and a manifest.
make_export() {
  mkdir -p "$T/export"
  echo "<plist>com.example.alpha new</plist>" >"$T/export/com.example.alpha.plist"
  echo "<plist>com.example.alpha new-host</plist>" >"$T/export/com.example.alpha.byhost.plist"
  printf 'macprefs_version 2\nmacos_version 26.0\n' >"$T/export/MANIFEST.txt"
}

test_import_saves_a_rollback_before_it_imports() {
  set_pref com.example.alpha old
  set_pref com.example.alpha old-host byhost
  make_export
  mac_prefs import "$T/export" --yes
  STATUS=$?
  expect_status 0
  local rollback
  rollback="$(ls -d "$HOME"/.mac-prefs-rollback/*/ 2>/dev/null | head -n 1)"
  [ -n "$rollback" ] || fail "no rollback folder"
  expect_content "${rollback}com.example.alpha.plist" "<plist>com.example.alpha old</plist>"
  expect_content "${rollback}com.example.alpha.byhost.plist" "<plist>com.example.alpha old-host</plist>"
  expect_content "$FAKE_PREFS/com.example.alpha.plist" "<plist>com.example.alpha new</plist>"
  expect_content "$FAKE_PREFS/com.example.alpha.byhost.plist" "<plist>com.example.alpha new-host</plist>"
  expect_output "2 imported, 0 failed"
}

test_import_dry_run_changes_nothing() {
  set_pref com.example.alpha old
  make_export
  mac_prefs import "$T/export" --dry-run
  STATUS=$?
  expect_status 0
  expect_content "$FAKE_PREFS/com.example.alpha.plist" "<plist>com.example.alpha old</plist>"
  expect_no_file "$FAKE_PREFS/imports.log"
  expect_no_file "$HOME/.mac-prefs-rollback"
}

test_import_skips_a_corrupt_file_and_fails() {
  make_export
  echo "CORRUPT" >"$T/export/com.example.alpha.byhost.plist"
  mac_prefs import "$T/export" --yes
  STATUS=$?
  expect_status 1
  expect_output "corrupt plist, skipping"
  expect_content "$FAKE_PREFS/com.example.alpha.plist" "<plist>com.example.alpha new</plist>"
  expect_no_file "$FAKE_PREFS/com.example.alpha.byhost.plist"
}

test_export_warns_about_a_domain_name_with_an_underscore() {
  printf 'com.example.my_app\n' >"$T/conf"
  set_pref com.example.my_app 1
  mac_prefs export "$T/out-dir"
  STATUS=$?
  expect_status 0
  expect_output "com.example.my_app -- name does not round-trip"
  expect_file "$T/out-dir/latest/com.example.my_app.plist"
}

# ---------------------------------------------------------------- runner

for name in $(declare -F | awk '{print $3}' | grep '^test_'); do
  case "$name" in *"$FILTER"*) ;; *) continue ;; esac
  RUN=$((RUN + 1))
  FAILED=0
  setup
  "$name"
  if [ "$FAILED" -eq 0 ]; then
    echo "ok      ${name#test_}"
  else
    echo "FAILED  ${name#test_}"
    sed 's/^/    | /' "$T/out" 2>/dev/null
    FAILURES=$((FAILURES + 1))
  fi
  teardown
done

echo
echo "$RUN run, $FAILURES failed"
[ "$RUN" -gt 0 ] && [ "$FAILURES" -eq 0 ]
