#!/bin/sh
set -eu
package=$1
digest=$2
current=$3
parent_pid=$4
job=$5
staged=
backup=
exited=false
fail() {
  printf '%s\n' "$1" > "$job/error.txt"
  exit 1
}
cleanup() {
  status=$?
  if [ "$status" -ne 0 ]; then
    if [ ! -f "$job/error.txt" ]; then printf '%s\n' '更新未完成，请从原路径重新打开华润赢，或重试安装。' > "$job/error.txt"; fi
    if [ "$exited" = true ]; then nohup "$current" >/dev/null 2>&1 & fi
  fi
  if [ -n "$staged" ]; then rm -f -- "$staged"; fi
}
trap cleanup EXIT
trap 'fail "更新准备已中断，原客户端与安装包已保留。"' HUP INT TERM
case "$parent_pid" in ''|*[!0-9]*) fail '更新进程信息无效。';; esac
[ -f "$package" ] && [ ! -L "$package" ] || fail '更新包不存在。'
[ -f "$current" ] && [ ! -L "$current" ] || fail '当前 AppImage 路径已变化。'
[ "$(readlink -f -- "$current")" = "$current" ] || fail '当前 AppImage 路径包含符号链接。'
actual=$(sha256sum -- "$package")
[ "${actual%% *}" = "$digest" ] || fail '更新包 SHA-256 不匹配。'
old=$(sha256sum -- "$current")
old=${old%% *}
staged=$(mktemp "${current}.update.XXXXXX") || fail '无法写入 AppImage 所在目录，请检查权限。'
cp -- "$package" "$staged" || fail '无法准备更新副本。'
chmod 700 "$staged"
actual=$(sha256sum -- "$staged")
[ "${actual%% *}" = "$digest" ] || fail '更新副本校验失败。'
[ ! -e "$job/cancel" ] || exit 0
printf ready > "$job/ready"
attempt=0
while kill -0 "$parent_pid" 2>/dev/null; do
  [ ! -e "$job/cancel" ] || exit 0
  attempt=$((attempt + 1))
  [ "$attempt" -le 120 ] || fail '客户端尚未退出，更新已取消。'
  sleep 1
done
[ ! -e "$job/cancel" ] || exit 0
exited=true
[ ! -L "$current" ] || fail 'AppImage 路径已变化，更新未执行。'
actual=$(sha256sum -- "$current")
[ "${actual%% *}" = "$old" ] || fail '当前 AppImage 已变化，更新未执行。'
backup=$(mktemp "${current}.backup.XXXXXX") || fail '无法备份当前客户端。'
cp -p -- "$current" "$backup" || fail '无法备份当前客户端。'
mv -f -- "$staged" "$current" || fail '无法替换当前客户端，旧版已保留。'
staged=
printf installed > "$job/result"
nohup "$current" >/dev/null 2>&1 &
printf '%s\n' "$backup" > "$job/backup-path"
