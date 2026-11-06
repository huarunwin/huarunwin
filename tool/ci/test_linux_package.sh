#!/bin/bash
set -euo pipefail

archive=${1:-}
[[ -n "$archive" && -f "$archive" ]] || {
  echo 'Usage: test_linux_package.sh <linux-package.tar.gz>' >&2
  exit 1
}

root="${RUNNER_TEMP:-$(mktemp -d)}/huarunwin-linux-package"
rm -rf "$root"
mkdir -p "$root"
tar -xzf "$archive" -C "$root"

launcher="$root/huarunwin"
[[ -x "$launcher" ]] || {
  echo "Extracted Linux package has no executable launcher: $launcher" >&2
  exit 1
}

log="$root/launch.log"
GDK_BACKEND=x11 xvfb-run --auto-servernum \
  --server-args='-screen 0 1280x800x24' \
  "$launcher" >"$log" 2>&1 &
pid=$!

cleanup() {
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}
trap cleanup EXIT

for _ in {1..20}; do
  if ! kill -0 "$pid" 2>/dev/null; then
    status=0
    wait "$pid" || status=$?
    cat "$log"
    echo "Linux package launcher exited before the smoke-test window (status $status)" >&2
    exit 1
  fi
  sleep 1
done

echo 'Linux package launcher stayed alive for the smoke-test window.'
