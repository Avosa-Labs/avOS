#!/usr/bin/env sh
# Confirms the graphics architecture's prohibitions hold in the source (CI.3).
#
# The rebuild's rule is that the retained Zig compositor owns every frame. Skia, HarfBuzz,
# FreeType and the GPU APIs are engines behind Zig adapters, never the architecture — and an
# immediate-mode GUI toolkit or a second renderer is never allowed in at all. SDL2 is a
# dev-host surface only: it may be linked to put the OS in a window on a developer's machine,
# but it is compiled out of every product image, so it must never be linked from anywhere but
# the guarded desktop build step. This catches a violation entering the source.
#
# The scan covers build and code files, not prose: an ADR may name ImGui to record why it is
# refused. The type level already proves SDL2 cannot ship (presentation.mayShip); this is the
# source-level half.
#
# Exit codes: 0 clean, 1 a prohibition is violated.

set -eu

repository_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repository_root"

status=0

# 1. No immediate-mode GUI toolkit or second renderer enters the build. Pathspecs are quoted
#    so the shell does not glob-expand them against the working directory before git sees them.
if git grep -n -I -i -E 'imgui|cimgui|nuklear|nanovg|raylib' -- \
        '*.zig' '*.zon' '*.sh' '*.json' '*.yml' '*.yaml' \
        ':!infrastructure/ci/prohibitions.sh' >/dev/null 2>&1; then
    echo 'prohibitions: a forbidden GUI toolkit or second renderer appears in tracked source:' >&2
    git grep -n -I -i -E 'imgui|cimgui|nuklear|nanovg|raylib' -- \
        '*.zig' '*.zon' '*.sh' '*.json' '*.yml' '*.yaml' \
        ':!infrastructure/ci/prohibitions.sh' >&2
    echo 'The Zig compositor owns every frame; engines live behind adapters, GUI toolkits are refused.' >&2
    status=1
fi

# 2. SDL2 is linked only from the build script — never from a library or product module.
if git grep -n -I -e 'linkSystemLibrary("SDL' -- '*.zig' ':!build.zig' >/dev/null 2>&1; then
    echo 'prohibitions: SDL2 is linked outside the build script (must stay a dev-host surface):' >&2
    git grep -n -I -e 'linkSystemLibrary("SDL' -- '*.zig' ':!build.zig' >&2
    status=1
fi

# 3. In the build script, SDL2 is linked only after the dev-host guard (sdlPrefix), so a
#    product image — built without a display prefix — never links it.
guard_line=$(grep -n 'sdlPrefix(b)) |' build.zig | head -1 | cut -d: -f1 || true)
link_line=$(grep -n 'linkSystemLibrary("SDL' build.zig | head -1 | cut -d: -f1 || true)
if [ -n "$link_line" ]; then
    if [ -z "$guard_line" ] || [ "$link_line" -le "$guard_line" ]; then
        echo 'prohibitions: SDL2 is linked in build.zig outside the sdlPrefix dev-host guard.' >&2
        status=1
    fi
fi

if [ "$status" -eq 0 ]; then
    echo 'prohibitions: no forbidden toolkit, and SDL2 stays a dev-host surface'
fi
exit "$status"
