#!/usr/bin/env bash
# keepsake smoke tests — end-to-end backup/restore against a throwaway $HOME.
#
#   tests/smoke.sh
#
# Nothing here touches your real home directory or your real snapshots: every
# case runs with HOME, XDG_CONFIG_HOME and KEEPSAKE_DIR pointed at a temp
# tree that is removed on exit.

# Assertions are eval'd, so shellcheck cannot see where these variables are read.
# shellcheck disable=SC2034
set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
KEEPSAKE="$REPO/keepsake"

PASS=0
FAIL=0
CURRENT=""

RED=$'\033[31m'; GRN=$'\033[32m'; DIM=$'\033[2m'; RST=$'\033[0m'
[[ -t 1 ]] || { RED=''; GRN=''; DIM=''; RST=''; }

it()   { CURRENT=$1; printf '%s… %s%s\n' "$DIM" "$CURRENT" "$RST"; }
pass() { PASS=$((PASS + 1)); printf '%s  ✔%s %s\n' "$GRN" "$RST" "${1:-$CURRENT}"; }
fail() { FAIL=$((FAIL + 1)); printf '%s  ✖%s %s: %s\n' "$RED" "$RST" "$CURRENT" "$1" >&2; }

assert()      { if eval "$1"; then pass "${2:-$1}"; else fail "${2:-$1} — [$1] was false"; fi; }
assert_file() { [[ -f $1 ]] && pass "exists: ${1#"$SANDBOX/"}" || fail "missing file: $1"; }
assert_dir()  { [[ -d $1 ]] && pass "exists: ${1#"$SANDBOX/"}" || fail "missing dir: $1"; }
assert_no()   { [[ ! -e $1 ]] && pass "absent: ${1#"$SANDBOX/"}" || fail "should not exist: $1"; }

SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/keepsake-smoke.XXXXXX")
trap 'rm -rf "$SANDBOX"' EXIT

# A throwaway home with a few of the files the bundled manifest's [core]
# group asks for, plus a secret that must stay out of default backups.
new_home() {
  local h="$SANDBOX/$1"
  rm -rf "$h"
  mkdir -p "$h/.config/git" "$h/.ssh"
  printf 'export SMOKE=1\n'        > "$h/.zshrc"
  printf '[user]\n\tname = Smoke\n' > "$h/.gitconfig"
  printf 'core-config\n'            > "$h/.config/git/config"
  printf 'PRIVATE KEY MATERIAL\n'   > "$h/.ssh/id_ed25519"
  chmod 600 "$h/.ssh/id_ed25519"
  printf '%s\n' "$h"
}

# run HOME_DIR ARGS... — invoke keepsake fully sandboxed
run() {
  local home=$1; shift
  HOME="$home" \
  XDG_CONFIG_HOME="$home/.config" \
  KEEPSAKE_DIR="$SANDBOX/snapshots" \
  KEEPSAKE_DEV="$home/Dev" \
    "$KEEPSAKE" "$@"
}

printf '\nkeepsake smoke tests\n=====================\n\n'

# ---------------------------------------------------------------------------
it "help and version"
# ---------------------------------------------------------------------------
H=$(new_home h0)
run "$H" help    >/dev/null 2>&1 && pass "keepsake help"    || fail "help exited non-zero"
run "$H" --version >/dev/null 2>&1 && pass "keepsake --version" || fail "--version exited non-zero"
run "$H" bogus-command >/dev/null 2>&1 && fail "unknown command should exit non-zero" || pass "unknown command rejected"

# ---------------------------------------------------------------------------
it "DISTROHOP_DIR still selects the snapshot dir"
# ---------------------------------------------------------------------------
LEGACY_DIR="$SANDBOX/legacy-snapshots"
mkdir -p "$LEGACY_DIR"
HOME="$H" XDG_CONFIG_HOME="$H/.config" DISTROHOP_DIR="$LEGACY_DIR" \
  "$KEEPSAKE" backup --name legacy --groups core >/dev/null 2>&1
assert_file "$LEGACY_DIR/legacy/files/.zshrc"

# ---------------------------------------------------------------------------
it "moves ~/.config/distrohop to ~/.config/keepsake"
# ---------------------------------------------------------------------------
HLEG=$(new_home hlegacy)
mkdir -p "$HLEG/.config/distrohop"
printf 'dev_root=/tmp/from-legacy-config\n' > "$HLEG/.config/distrohop/settings.conf"
GOT=$(HOME="$HLEG" XDG_CONFIG_HOME="$HLEG/.config" KEEPSAKE_DIR="$SANDBOX/snapshots" \
        "$KEEPSAKE" config get dev_root)
assert "[[ \$GOT == /tmp/from-legacy-config ]]" "config get still works after the move"
assert_dir "$HLEG/.config/keepsake"
assert_file "$HLEG/.config/keepsake/settings.conf"
assert_no "$HLEG/.config/distrohop"

# ---------------------------------------------------------------------------
it "moves ~/Backups/distrohop to ~/Backups/keepsake and lists those snapshots"
# ---------------------------------------------------------------------------
HM=$(new_home hmig)
mkdir -p "$HM/Backups/distrohop/oldsnap/files" "$HM/Backups/distrohop/oldsnap/meta"
printf '2026-08-01T00:00:00+00:00\n' > "$HM/Backups/distrohop/oldsnap/meta/date"
MIGOUT=$(HOME="$HM" XDG_CONFIG_HOME="$HM/.config" "$KEEPSAKE" list 2>&1)
assert_dir "$HM/Backups/keepsake/oldsnap"
assert_no "$HM/Backups/distrohop"
assert "grep -q oldsnap <<< \"\$MIGOUT\"" "list shows the moved snapshot"
assert "grep -q 'Backups/keepsake' <<< \"\$(HOME=\"\$HM\" XDG_CONFIG_HOME=\"\$HM/.config\" \"\$KEEPSAKE\" -h)\"" "help names the keepsake backup dir"

# ---------------------------------------------------------------------------
it "install links keepsake and a distrohop alias"
# ---------------------------------------------------------------------------
run "$H" install >/dev/null 2>&1
assert "[[ -L $H/.local/bin/keepsake ]]" "install created ~/.local/bin/keepsake"
assert "[[ -L $H/.local/bin/distrohop ]]" "install left distrohop as an alias"

# ---------------------------------------------------------------------------
it "install swaps a leftover distrohop-backup systemd timer for keepsake-backup (regression)"
# ---------------------------------------------------------------------------
# A pre-rename install left distrohop-backup.timer pointed at
# ~/.local/bin/distrohop, which used to symlink straight at the old script
# file. After the rename that file is gone, so the timer silently stopped
# being able to run at all — install should finish the migration, not just
# the README.
HSD=$(new_home hsysd)
mkdir -p "$HSD/.config/systemd/user"
printf '[Timer]\nUnit=distrohop-backup.service\n' > "$HSD/.config/systemd/user/distrohop-backup.timer"
printf '[Service]\nExecStart=%%h/.local/bin/distrohop backup\n' > "$HSD/.config/systemd/user/distrohop-backup.service"
run "$HSD" install >/dev/null 2>&1
assert_no "$HSD/.config/systemd/user/distrohop-backup.timer"
assert_no "$HSD/.config/systemd/user/distrohop-backup.service"
assert_file "$HSD/.config/systemd/user/keepsake-backup.timer"
assert_file "$HSD/.config/systemd/user/keepsake-backup.service"
assert "grep -q keepsake-backup.service $HSD/.config/systemd/user/keepsake-backup.timer" "migrated timer points at keepsake-backup.service"

# ---------------------------------------------------------------------------
it "install leaves systemd alone when there was never a distrohop timer"
# ---------------------------------------------------------------------------
HSD2=$(new_home hsysd2)
mkdir -p "$HSD2/.config/systemd/user"
run "$HSD2" install >/dev/null 2>&1
assert_no "$HSD2/.config/systemd/user/keepsake-backup.timer"

# ---------------------------------------------------------------------------
it "edit opens the manifest in micro even when EDITOR is set"
# ---------------------------------------------------------------------------
EDITBIN="$SANDBOX/editbin"
mkdir -p "$EDITBIN"
cat > "$EDITBIN/micro" <<EOF
#!/bin/sh
printf '%s\n' "\$1" > "$SANDBOX/opened-by-micro"
EOF
cat > "$EDITBIN/nano" <<EOF
#!/bin/sh
printf '%s\n' "\$1" > "$SANDBOX/opened-by-nano"
EOF
chmod +x "$EDITBIN/micro" "$EDITBIN/nano"
HED=$(new_home hedit)
HOME="$HED" XDG_CONFIG_HOME="$HED/.config" KEEPSAKE_DIR="$SANDBOX/snapshots" \
  PATH="$EDITBIN:$PATH" EDITOR=nano \
  "$KEEPSAKE" edit >/dev/null
assert_file "$SANDBOX/opened-by-micro"
assert_no "$SANDBOX/opened-by-nano"
assert "grep -q manifest.conf '$SANDBOX/opened-by-micro'" "micro was given the manifest path"

# ---------------------------------------------------------------------------
it "the read-only commands survive a bare environment (set -u)"
# ---------------------------------------------------------------------------
# Containers, cron and `su` do not export USER/SHELL/LOGNAME. Under set -u a
# bare $USER anywhere in a code path is an "unbound variable" exit, which is
# how `keepsake help` came to fail on every distro container but not on a
# developer's terminal.
for cmd in help --version "status --groups core" list; do
  # shellcheck disable=SC2086
  if env -u USER -u SHELL -u LOGNAME \
       HOME="$H" XDG_CONFIG_HOME="$H/.config" KEEPSAKE_DIR="$SANDBOX/snapshots" \
       "$KEEPSAKE" $cmd >/dev/null 2>&1
  then pass "keepsake $cmd with USER/SHELL/LOGNAME unset"
  else fail "keepsake $cmd failed with USER/SHELL/LOGNAME unset"
  fi
done

# ---------------------------------------------------------------------------
it "status runs against a fresh home"
# ---------------------------------------------------------------------------
run "$H" status --groups core >/dev/null 2>&1 && pass "status --groups core" || fail "status exited non-zero"

# ---------------------------------------------------------------------------
it "backup --dry-run writes nothing (DRY_RUN invariant)"
# ---------------------------------------------------------------------------
rm -rf "$SANDBOX/snapshots"
run "$H" backup --name dry --groups core --dry-run >/dev/null 2>&1
assert_no "$SANDBOX/snapshots"

# ---------------------------------------------------------------------------
it "backup writes a snapshot without secrets by default"
# ---------------------------------------------------------------------------
run "$H" backup --name plain --groups core >/dev/null 2>&1
SNAP="$SANDBOX/snapshots/plain"
assert_dir  "$SNAP/files"
assert_file "$SNAP/MANIFEST.txt"
assert_file "$SNAP/NOTES.txt"
assert_file "$SNAP/meta/date"
assert_file "$SNAP/files/.zshrc"
assert_file "$SNAP/files/.config/git/config"
assert_no   "$SNAP/secrets"
assert "! grep -q PRIVATE '$SNAP/MANIFEST.txt'" "no secrets in MANIFEST.txt"

# ---------------------------------------------------------------------------
it "backup --secrets includes them, and locks the snapshot down"
# ---------------------------------------------------------------------------
run "$H" backup --name sec --groups core --secrets >/dev/null 2>&1
SEC="$SANDBOX/snapshots/sec"
assert_file "$SEC/secrets/.ssh/id_ed25519"
assert "[[ \$(stat -c %a '$SEC') == 700 ]]" "snapshot root is 0700 when it holds secrets"
assert "[[ \$(stat -c %a '$SEC/secrets') == 700 ]]" "secrets/ is 0700"

# ---------------------------------------------------------------------------
it "the package list is one name per line"
# ---------------------------------------------------------------------------
# dnf's --qf does not append a newline, so `--qf '%{name}'` silently produced
# every package name concatenated into a single line on Fedora. Assert the
# shape of the file rather than any particular package manager's output.
PKGS="$SNAP/packages/explicit.txt"
assert_file "$PKGS"
if [[ -s $PKGS ]]; then
  MAXLEN=$(wc -L < "$PKGS")
  assert "(( MAXLEN <= 120 ))" "no run-together line in explicit.txt (longest is $MAXLEN chars)"
  assert "! grep -q ' ' '$PKGS'" "no package name contains a space"
else
  pass "explicit.txt is empty on this host (no package manager, or nothing explicit)"
fi

# ---------------------------------------------------------------------------
it "SHA256SUMS and verify"
# ---------------------------------------------------------------------------
assert_file "$SNAP/SHA256SUMS"
run "$H" verify plain >/dev/null 2>&1 && pass "verify passes on an intact snapshot" \
                                      || fail "verify failed on an intact snapshot"
printf 'corrupted\n' >> "$SNAP/files/.zshrc"
run "$H" verify plain >/dev/null 2>&1 && fail "verify passed on a corrupted snapshot" \
                                      || pass "verify detects corruption"
printf 'export SMOKE=1\n' > "$SNAP/files/.zshrc"   # put it back for restore tests

# ---------------------------------------------------------------------------
it "restore puts files back and never clobbers silently"
# ---------------------------------------------------------------------------
H2=$(new_home h2)
printf 'PRE-EXISTING\n' > "$H2/.zshrc"
run "$H2" restore plain --groups core --yes >/dev/null 2>&1
assert "grep -q SMOKE '$H2/.zshrc'" "restored file content"
assert "compgen -G '$H2/.zshrc.pre-hop.*' >/dev/null" "clobbered file saved as *.pre-hop.*"
assert "grep -q PRE-EXISTING $H2/.zshrc.pre-hop.*" "the .pre-hop.* copy holds the old content"

# ---------------------------------------------------------------------------
it "restore of a no-secrets snapshot leaves secrets alone"
# ---------------------------------------------------------------------------
H3=$(new_home h3)
rm -f "$H3/.ssh/id_ed25519"
run "$H3" restore plain --groups core --secrets --yes >/dev/null 2>&1
assert_no "$H3/.ssh/id_ed25519"

# ---------------------------------------------------------------------------
it "prune drops the oldest by DATE, not by name (regression: custom --name)"
# ---------------------------------------------------------------------------
P="$SANDBOX/prune"
rm -rf "$P"
mk_snap() { mkdir -p "$P/$1/files" "$P/$1/meta"; printf '%s\n' "$2" > "$P/$1/meta/date"; }
# "workstation" sorts last by name but is by far the oldest by date
mk_snap workstation           2026-01-01T00:00:00+00:00
mk_snap 2026-08-19_100000_box 2026-08-19T10:00:00+00:00
mk_snap 2026-08-20_100000_box 2026-08-20T10:00:00+00:00
PRUNED=$(HOME="$H" XDG_CONFIG_HOME="$H/.config" KEEPSAKE_DIR="$P" \
           "$KEEPSAKE" prune --keep 2 --dry-run 2>/dev/null)
assert "grep -q 'would delete workstation' <<< \"\$PRUNED\"" "prune targets the oldest by date"
assert "! grep -q 'would delete 2026-08-20' <<< \"\$PRUNED\"" "prune spares the newest"

it "list shows newest first"
LISTED=$(HOME="$H" XDG_CONFIG_HOME="$H/.config" KEEPSAKE_DIR="$P" \
           "$KEEPSAKE" list 2>/dev/null | sed -n '2p')
assert "grep -q 2026-08-20 <<< \"\$LISTED\"" "newest snapshot is the first row"

# ---------------------------------------------------------------------------
it "s3 push never adds secrets to a snapshot that opted out (regression)"
# ---------------------------------------------------------------------------
# No s3.conf here, so the push cannot complete — the point is that it fails
# *without* having written ssh keys into the snapshot on its way out.
run "$H" s3 push plain >/dev/null 2>&1
assert_no "$SNAP/secrets"

# ---------------------------------------------------------------------------
it "works on a host with only bash, rsync and coreutils"
# ---------------------------------------------------------------------------
# Build a PATH holding only what the README claims to require. Everything
# else — python3, hostname, awk, column — is optional and must degrade rather
# than fail: openSUSE Tumbleweed ships no awk, and `du | awk` in a command
# substitution turned that into a hard exit under set -e.
MINI="$SANDBOX/minibin"
mkdir -p "$MINI"
for c in bash sh rsync find sort date mkdir cp mv rm chmod chown du grep sed \
         cat wc stat xargs sha256sum tar basename dirname head tail cut tr paste \
         tac ls uname comm touch env id readlink; do
  p=$(command -v "$c" 2>/dev/null) && ln -sf "$p" "$MINI/$c"
done
for missing in python3 hostname awk column; do
  assert "! PATH='$MINI' command -v $missing >/dev/null" "test PATH really has no $missing"
done

H4=$(new_home h4)
mini() { HOME="$H4" XDG_CONFIG_HOME="$H4/.config" KEEPSAKE_DIR="$SANDBOX/snapshots" \
         PATH="$MINI" "$KEEPSAKE" "$@"; }

OUT=$(mini backup --name mini --groups core 2>&1)
RC=$?
assert "(( $RC == 0 ))" "backup exits 0"
assert_file "$SANDBOX/snapshots/mini/files/.zshrc"
assert "grep -qi 'python3 not found' <<< \"\$OUT\"" "warned about the skipped dev-apps inventory"
assert_no "$SANDBOX/snapshots/mini/packages/dev-apps.json"

# These are the ones awk actually broke: both print a du size per row.
mini status --groups core >/dev/null 2>&1 && pass "status exits 0" || fail "status failed"
mini list >/dev/null 2>&1                 && pass "list exits 0"   || fail "list failed"
mini show mini >/dev/null 2>&1            && pass "show exits 0"   || fail "show failed"
MINI_LIST=$(mini list 2>/dev/null)
assert "[[ -n \$(sed -n '2p' <<< \"\$MINI_LIST\") ]]" "list renders rows, not just a header"
assert "grep -q mini <<< \"\$MINI_LIST\"" "list includes the snapshot just taken"

# ---------------------------------------------------------------------------
it "absolute manifest paths land in system/ and restore in place"
# ---------------------------------------------------------------------------
SYS="$SANDBOX/fake-etc/udev/hwdb.d"
mkdir -p "$SYS"
printf 'evdev:input:test*\n KEYBOARD_KEY_90004=reserved\n' > "$SYS/71-test.hwdb"
H5=$(new_home h5)
run "$H5" status --groups extra >/dev/null 2>&1
printf '%s/71-test.hwdb\n' "$SYS" >> "$H5/.config/keepsake/manifest.conf"
run "$H5" backup --name sysabs --groups extra >/dev/null 2>&1
assert_file "$SANDBOX/snapshots/sysabs/system$SYS/71-test.hwdb"
assert_no "$SANDBOX/snapshots/sysabs/files${SYS#/}/71-test.hwdb"
printf 'CHANGED\n' > "$SYS/71-test.hwdb"
run "$H5" restore sysabs --groups extra --yes >/dev/null 2>&1
assert "grep -q reserved '$SYS/71-test.hwdb'" "restored absolute path in place"
assert "compgen -G '$SYS/71-test.hwdb.pre-hop.*' >/dev/null" "clobbered abs path saved as *.pre-hop.*"

# ---------------------------------------------------------------------------
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
