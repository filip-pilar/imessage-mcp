#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

for script in "$ROOT"/scripts/*.sh "$ROOT"/distribution/standalone/install; do
    sh -n "$script"
done

developer_home_pattern="/""Users/"
if git -C "$ROOT" grep -n "$developer_home_pattern" -- .; then
    echo "Tracked configuration or code contains a developer-specific macOS home path." >&2
    exit 1
fi

"$ROOT/scripts/check-versions.sh"
"$ROOT/scripts/sync-distributions.sh" --check

case "${1:-}" in
    "")
        swift test --package-path "$ROOT" --no-parallel
        ;;
    --xcodebuild-tests)
        (
            cd "$ROOT"
            xcodebuild \
                -scheme iMessageMCP-Package \
                -destination "platform=macOS" \
                -parallel-testing-enabled NO \
                -quiet \
                test
        )
        ;;
    *)
        echo "Usage: $0 [--xcodebuild-tests]" >&2
        exit 2
        ;;
esac

echo "Repository checks passed."
