#!/usr/bin/env sh
# Confirms a vendored engine is never recompiled once it is built (the build cache).
#
# The vendored C/C++ engines — FreeType now, HarfBuzz and Skia to come — are expensive to
# compile, and CI must build each exactly once per pin, not once per run. Zig content-addresses
# every C/C++ object by its source bytes, flags, target, and compiler, so an engine whose pin
# has not changed compiles to the same cache entry and is not rebuilt. This gate holds that
# property to account: it warms the build, then rebuilds with the C compiler traced, and fails
# if a single engine source was compiled the second time. The per-run persistence that makes a
# warm cache exist across runs is the workflow's cache keyed on the pin digests; this asserts
# the content-addressing those keys rely on actually elides the work.
#
# A checkout that has not vendored the engines has nothing to compile and trivially passes.
#
# Exit codes: 0 no engine recompiled on a warm build, 1 an engine was rebuilt when it should
# have been cached.

set -eu

repository_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repository_root"

if [ ! -d .engines ]; then
    echo 'engine-cache: no engines vendored; nothing to cache'
    exit 0
fi

command -v zig >/dev/null 2>&1 || {
    echo 'engine-cache: zig is not on PATH; run tools/bootstrap/bootstrap.sh first' >&2
    exit 1
}

# Warm the cache: build everything once so every engine object is present.
zig build test >/dev/null 2>&1

# Rebuild with the C/C++ compiler traced. A warm, content-addressed cache must not run the
# compiler on any vendored engine source; count the ones it did.
recompiled=$(zig build test --verbose-cc 2>&1 | grep -Ec '/\.engines/[^ ]*\.(c|cc)([[:space:]]|$)' || true)

if [ "$recompiled" -ne 0 ]; then
    echo "engine-cache: a warm build recompiled ${recompiled} vendored engine source(s); the cache is not eliding the work:" >&2
    zig build test --verbose-cc 2>&1 | grep -E '/\.engines/[^ ]*\.(c|cc)([[:space:]]|$)' >&2 || true
    exit 1
fi

echo 'engine-cache: a warm build recompiled no vendored engine source'
