#!/usr/bin/env sh
# Installs the repository's Git hooks into this checkout.
#
# Hooks live in the repository so every contributor gets the same checks, and
# are copied rather than symlinked so a checkout without them still works.

set -eu

repository_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
source_directory="$repository_root/infrastructure/development/hooks"
target_directory="$repository_root/.git/hooks"

[ -d "$repository_root/.git" ] || {
    printf 'install: not a repository checkout\n' >&2
    exit 1
}

mkdir -p "$target_directory"

for hook in commit-msg pre-commit; do
    [ -f "$source_directory/$hook" ] || continue
    cp "$source_directory/$hook" "$target_directory/$hook"
    chmod +x "$target_directory/$hook"
    printf 'ok    installed %s\n' "$hook"
done
