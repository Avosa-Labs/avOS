#!/usr/bin/env sh
# Confirms every authored source file is tracked by version control.
#
# A contributor's global ignore file can carry a pattern that happens to match a
# directory this repository owns. The file then builds and tests locally and is
# absent from the repository, so the failure appears on another machine as code
# that does not exist. This catches that before it is pushed.
#
# Exit codes: 0 every authored file is tracked, 1 at least one is not.

set -eu

repository_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repository_root"

# Trees the repository authors, derived from the directories that exist rather
# than listed by hand. A hand-maintained list silently stops covering a
# directory added after it was written, which is the failure this gate exists to
# catch.
authored=$(find . -maxdepth 1 -type d ! -name '.*' ! -name out ! -name zig-out \
    -exec basename {} \; | sort)

# The specification is deliberately local-only and is expected to be untracked.
specification='docs/PLATFORM_SPEC.md'

untracked=0

for tree in $authored; do
    [ -d "$tree" ] || continue
    for file in $(find "$tree" -type f \
        \( -name '*.zig' -o -name '*.zon' -o -name '*.sh' -o -name '*.ps1' \
           -o -name '*.json' -o -name '*.md' -o -name '*.wat' -o -name '*.wit' \) 2>/dev/null)
    do
        case "$file" in
            "$specification") continue ;;
        esac
        if ! git ls-files --error-unmatch "$file" >/dev/null 2>&1; then
            printf '%s is not tracked\n' "$file" >&2
            untracked=$((untracked + 1))
        fi
    done
done

if [ "$untracked" -ne 0 ]; then
    printf '\nsource-tracked: %d authored file(s) are not in version control\n' "$untracked" >&2
    printf 'Run: git check-ignore -v <path>   to find the pattern excluding one,\n' >&2
    printf 'including patterns from a personal ignore file outside this repository.\n' >&2
    exit 1
fi

printf 'source-tracked: every authored source file is tracked\n'
