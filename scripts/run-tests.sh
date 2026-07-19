#!/usr/bin/env bash
# Compile Domain + Infra + AppCore + Adapters + Tests into a temporary binary and run (no Xcode project).
set -euo pipefail

cd "$(dirname "$0")/.."

BUILD_DIR="./build/tests"
mkdir -p "$BUILD_DIR"

DOMAIN_SOURCES=$(find Sources/Domain -name '*.swift' | sort)
INFRA_SOURCES=$(find Sources/Infra -name '*.swift' | sort)
APPCORE_SOURCES=$(find Sources/AppCore -name '*.swift' | sort)
ADAPTER_SOURCES=$(find Sources/Adapters -name '*.swift' | sort)
TEST_SOURCES=$(find Tests -name '*.swift' | sort)

if [[ -z "$TEST_SOURCES" ]]; then
  echo "error: no Tests/*.swift found" >&2
  exit 1
fi

OUT="$BUILD_DIR/DashIslandTests"

# shellcheck disable=SC2086
swiftc \
  -target "arm64-apple-macos13.0" \
  -parse-as-library \
  -O \
  -framework Combine \
  -framework Security \
  -o "$OUT" \
  $DOMAIN_SOURCES \
  $INFRA_SOURCES \
  $APPCORE_SOURCES \
  $ADAPTER_SOURCES \
  $TEST_SOURCES

echo "→ running $OUT"
"$OUT"
