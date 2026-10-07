#!/bin/sh
set -eu
cd "$(dirname "$0")"
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "需要安装 XcodeGen：brew install xcodegen" >&2
  exit 1
fi
xcodegen generate --spec project.yml
