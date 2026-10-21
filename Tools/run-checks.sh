#!/bin/bash
#
#  run-checks.sh — compile and run every Tools/check-*.swift.
#
#  Each check documents its own compile line in its header comment
#  ("swiftc -O -o /tmp/NAME \ SOURCES…"). This reads that line, so a new
#  check is picked up by existing — and a check whose documented sources
#  no longer compile fails here instead of rotting quietly, which is what
#  happened when TeamSheet.swift began to need SheetTidy.swift.
#
#  Usage (from the repository root):
#      Tools/run-checks.sh            # every check
#      Tools/run-checks.sh --live     # also audit the real team sheet
#
#  Exit status is non-zero if any check fails to build or fails.
#

set -u
cd "$(dirname "$0")/.." || exit 2

failed=0
passed=0

run_check() {
    local file="$1"
    # The header lines from `swiftc -O -o` up to the first line that does
    # not end in a backslash.
    local spec
    spec=$(awk '
        /swiftc -O -o/ { on = 1 }
        on {
            sub(/^\/\/[[:space:]]*/, "")
            cont = ($0 ~ /\\[[:space:]]*$/)
            sub(/\\[[:space:]]*$/, "")
            printf "%s ", $0
            if (!cont) exit
        }' "$file")
    if [ -z "$spec" ]; then
        # A script-style check ("swift Tools/NAME.swift") runs as it is.
        if grep -q "^//[[:space:]]*swift Tools/" "$file"; then
            local result
            if result=$(swift "$file" 2>&1); then
                echo "ok   $(basename "$file") — $(echo "$result" | tail -1)"
                passed=$((passed + 1))
            else
                echo "FAIL $(basename "$file")"
                echo "$result" | tail -5 | sed 's/^/       /'
                failed=$((failed + 1))
            fi
            return
        fi
        echo "FAIL $(basename "$file") — no compile line in its header"
        failed=$((failed + 1))
        return
    fi

    local words=($spec)          # swiftc -O -o OUT SRC...
    local out="${words[3]}"
    local sources=("${words[@]:4}")

    local log
    log=$(mktemp)
    if ! swiftc -O -o "$out" "${sources[@]}" >"$log" 2>&1; then
        echo "FAIL $(basename "$file") — does not build:"
        grep -m3 "error" "$log" | sed 's/^/       /'
        failed=$((failed + 1))
        rm -f "$log"
        return
    fi
    rm -f "$log"

    local result
    if result=$("$out" 2>&1); then
        echo "ok   $(basename "$file") — $(echo "$result" | tail -1)"
        passed=$((passed + 1))
    else
        echo "FAIL $(basename "$file")"
        echo "$result" | grep -E "^FAIL|failure" | sed 's/^/       /'
        failed=$((failed + 1))
    fi
}

for file in Tools/check-*.swift; do
    run_check "$file"
done

if [ "${1:-}" = "--live" ]; then
    echo
    echo "── live team sheet (read-only) ──"
    # The tool's own header gives its compile line; this follows it.
    if swiftc -O -o /tmp/liveaudit Sources/Team/TeamSheet.swift Sources/Team/SheetTidy.swift \
        Sources/Feed/SongSearchSuggestions.swift Sources/Feed/PlanSongTitle.swift \
        Sources/Team/SongTitleTidy.swift Sources/Team/SheetAudit.swift Tools/audit-live-sheet.swift 2>/dev/null; then
        # Addresses are masked: this output ends up in logs and chats.
        /tmp/liveaudit | sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+/<address>/g'
        [ "${PIPESTATUS[0]}" -eq 1 ] && failed=$((failed + 1))
    else
        echo "FAIL audit-live-sheet.swift — does not build"
        failed=$((failed + 1))
    fi
fi

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
