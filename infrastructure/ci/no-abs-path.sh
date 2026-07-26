#!/usr/bin/env sh
# Confirms no tracked source hardcodes a developer-machine absolute path.
#
# The reference design and other developer-local artifacts live outside the repo and are
# reached through local config (env or .local/), never a literal path baked into a tool,
# test, or build step. A hardcoded "/Users/<name>/..." would build on one machine and
# break on every other — and quietly change where the design comes from. This catches it.
#
# Exit codes: 0 clean, 1 a hardcoded path found.

set -eu

repository_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repository_root"

# Documentation may legitimately show an example path in prose; source may not.
if git grep -n -I -e '/Users/' -- '*.zig' '*.zon' '*.sh' '*.json' '*.ps1' '*.yml' '*.yaml' ':!infrastructure/ci/no-abs-path.sh' >/dev/null 2>&1; then
    echo 'no-abs-path: a tracked source file hardcodes a developer absolute path:' >&2
    git grep -n -I -e '/Users/' -- '*.zig' '*.zon' '*.sh' '*.json' '*.ps1' '*.yml' '*.yaml' ':!infrastructure/ci/no-abs-path.sh' >&2
    echo 'Reach developer-local files through local config (DESIGN_REFERENCE_PATH or .local/), never a literal path.' >&2
    exit 1
fi

echo 'no-abs-path: no hardcoded developer paths in tracked source'
