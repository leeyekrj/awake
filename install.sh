#!/bin/bash
# Awake GitHub installer. Installs only the app; helper setup is opt-in in the app.
set -euo pipefail
version=v1.1.3
app_dir=/Applications
launch=1
die() { printf 'Awake: %s\n' "$*" >&2; exit 1; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --version|--app-dir)
      [ "$#" -ge 2 ] || die "$1 값이 필요합니다."
      case "$1" in --version) version="$2";; --app-dir) app_dir="$2";; esac
      shift 2;;
    --no-open) launch=0; shift;;
    --help) printf '%s\n' '사용: bash install.sh [--version v1.1.3] [--app-dir 경로] [--no-open]'; exit 0;;
    *) die "알 수 없는 옵션: $1";;
  esac
done
[ "$(uname -s)" = Darwin ] || die 'macOS 14 이상에서 설치할 수 있습니다.'
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || die 'macOS 14 이상이 필요합니다.'
case "$(uname -m)" in arm64|x86_64) ;; *) die 'Apple Silicon 또는 Intel Mac이 필요합니다.';; esac
[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die '버전 형식은 v1.1.3입니다.'
case "$app_dir" in *$'\n'*|*$'\r'*) die '경로에 줄바꿈을 쓸 수 없습니다.';; esac
case "$app_dir" in /*) ;; *) die '--app-dir에는 절대 경로를 사용하세요.';; esac
if [ "$app_dir" = /Applications ] && [ ! -w /Applications ]; then app_dir="$HOME/Applications"; fi
app="$app_dir/Awake.app"
if /bin/ps -axo comm= | /usr/bin/grep -Fxq "$app/Contents/MacOS/Awake"; then
  die 'Awake를 메뉴에서 종료한 뒤 다시 설치하세요. 설정과 기록은 유지됩니다.'
fi
tmp=$(mktemp -d "${TMPDIR:-/tmp}/awake-install.XXXXXX")
stage=''; backup=''
cleanup() {
  [ -z "$stage" ] || rm -rf "$stage"
  if [ -n "$backup" ] && [ -d "$backup" ] && [ ! -e "$app" ]; then mv "$backup" "$app"; fi
  rm -rf "$tmp"
}
trap cleanup EXIT
asset="Awake-${version#v}-macOS-universal.zip"
base="https://github.com/leeyekrj/awake/releases/download/$version"
printf 'Awake %s 다운로드 중…\n' "$version"
curl --fail --location --retry 3 --proto '=https' --tlsv1.2 "$base/$asset" -o "$tmp/$asset"
curl --fail --location --retry 3 --proto '=https' --tlsv1.2 "$base/SHA256SUMS.txt" -o "$tmp/SHA256SUMS.txt"
expected=$(awk -v file="$asset" '$2 == file {print $1}' "$tmp/SHA256SUMS.txt")
[[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die '릴리스의 SHA256을 확인할 수 없습니다.'
actual=$(shasum -a 256 "$tmp/$asset" | awk '{print $1}')
[ "$actual" = "$expected" ] || die '다운로드 검증 실패. 설치하지 않았습니다.'
ditto -x -k "$tmp/$asset" "$tmp/unpacked"
source_app="$tmp/unpacked/Awake.app"
codesign --verify --strict "$source_app"
[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$source_app/Contents/Info.plist")" = io.paul.awake ] || die '앱 식별자가 다릅니다.'
[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$source_app/Contents/Info.plist")" = "${version#v}" ] || die '앱 버전이 다릅니다.'
mkdir -p "$app_dir"
stage=$(mktemp -d "$app_dir/.awake-install.XXXXXX")
ditto "$source_app" "$stage/Awake.app"
if [ -e "$app" ]; then
  backup="$app_dir/Awake.app.backup-$(date +%Y%m%d-%H%M%S)-$$"
  mv "$app" "$backup"
fi
mv "$stage/Awake.app" "$app"
printf '설치 완료: %s\n' "$app"
[ -z "$backup" ] || printf '이전 앱 백업: %s\n' "$backup"
printf '%s\n' '현재 릴리스는 Apple 미공증 앱입니다. 실행이 차단되면 시스템 설정 → 개인정보 보호 및 보안 → 그래도 열기를 확인하세요.'
if [ "$launch" = 1 ]; then open "$app" || printf '앱을 직접 열어 주세요.\n'; fi
