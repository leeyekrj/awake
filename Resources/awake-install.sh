#!/bin/bash
# Called only after the wizard's explicit consent and the macOS admin dialog.
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
SOURCE=$(cd "$(dirname "$0")" && pwd)
TARGET_USER=${1:?Missing user}
TEST_ROOT=${2:-}
case "$TARGET_USER" in ''|*[!a-zA-Z0-9_.-]*) echo '사용자 이름을 확인할 수 없습니다.' >&2; exit 2 ;; esac
TARGET_UID=$(/usr/bin/id -u "$TARGET_USER")
[ "$TARGET_UID" -ne 0 ] || exit 2
if [ -n "$TEST_ROOT" ]; then
  [ "${AWAKE_INSTALL_TESTING:-}" = 1 ] && [[ "$TEST_ROOT" = /private/tmp/awake-install-test-* ]] || exit 2
  EXPECTED_OWNER=$EUID
else
  [ "$EUID" -eq 0 ] || { echo '관리자 승인이 필요합니다.' >&2; exit 1; }
  EXPECTED_OWNER=0
fi
BASE="$TEST_ROOT/Library/Application Support/Awake"
DAEMONS="$TEST_ROOT/Library/LaunchDaemons"
SUDOERS="$TEST_ROOT/private/etc/sudoers.d"
LABEL=io.paul.awake.lidawake
# Reject an existing symlink or user-writable directory before granting access.
secure_dir() {
  local directory="$1" owner mode
  [ ! -L "$directory" ] || { echo '설치 경로가 올바르지 않습니다.' >&2; exit 1; }
  if [ -e "$directory" ]; then
    [ -d "$directory" ] || exit 1
    owner=$(stat -f %u "$directory"); mode=$(stat -f %OLp "$directory")
    [ "$owner" -eq "$EXPECTED_OWNER" ] && (( (8#$mode & 022) == 0 )) || {
      echo '설치 경로의 소유권과 권한을 확인해 주세요.' >&2; exit 1;
    }
  else
    mkdir -p "$directory"; chmod 755 "$directory"
    [ -n "$TEST_ROOT" ] || chown root:wheel "$directory"
  fi
}
for directory in "$TEST_ROOT/Library" "$TEST_ROOT/Library/Application Support" "$BASE" "$DAEMONS" "$TEST_ROOT/private" "$TEST_ROOT/private/etc" "$SUDOERS"; do secure_dir "$directory"; done
TEMP_RULE=$(mktemp "$SUDOERS/.awake-rule.XXXXXX")
trap 'rm -f "$TEMP_RULE"' EXIT
printf '%s ALL=(root) NOPASSWD: /Library/Application\\ Support/Awake/lidawake\n' "$TARGET_USER" > "$TEMP_RULE"
/usr/sbin/visudo -c -f "$TEMP_RULE" >/dev/null
install_file() {
  local mode="$1" source="$2" dest="$3"
  [ ! -L "$dest" ] || { echo '설치 파일 경로가 올바르지 않습니다.' >&2; exit 1; }
  if [ -n "$TEST_ROOT" ]; then install -m "$mode" "$source" "$dest"
  else install -m "$mode" -o root -g wheel "$source" "$dest"; fi
}
install_file 755 "$SOURCE/awake-lidawake" "$BASE/lidawake"
install_file 755 "$SOURCE/awake-watchdog" "$BASE/lidawake-watchdog"
PLIST=$(mktemp "$BASE/.daemon.XXXXXX")
cat > "$PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>io.paul.awake.lidawake</string>
<key>ProgramArguments</key><array><string>/Library/Application Support/Awake/lidawake-watchdog</string></array>
<key>RunAtLoad</key><true/>
<key>StartInterval</key><integer>60</integer>
<key>StandardErrorPath</key><string>/Library/Logs/awake-lidawake-daemon.log</string>
<key>ProcessType</key><string>Background</string>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$PLIST" >/dev/null
install_file 644 "$PLIST" "$DAEMONS/$LABEL.plist"
rm -f "$PLIST"
install_file 440 "$TEMP_RULE" "$SUDOERS/awake-lidawake-$TARGET_UID"
if [ -z "$TEST_ROOT" ]; then
  touch /Library/Logs/lidawake.log; chmod 644 /Library/Logs/lidawake.log
  /bin/launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
  /bin/launchctl bootstrap system "$DAEMONS/$LABEL.plist"
  /bin/launchctl print "system/$LABEL" >/dev/null
fi
echo 'Awake helper installed'
