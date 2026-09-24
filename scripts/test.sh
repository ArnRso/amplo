#!/bin/zsh
# Tests du package AmploDSP, avertissements bloquants, puis sous Address Sanitizer.
set -euo pipefail
cd "${0:A:h}/.."

swift test --package-path Packages/AmploDSP -Xswiftc -warnings-as-errors
swift test --package-path Packages/AmploDSP -Xswiftc -warnings-as-errors --sanitize=address
