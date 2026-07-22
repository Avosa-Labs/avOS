#!/usr/bin/env sh
# Prepares a checkout to build without touching system-wide state.
#
# Resolves the compiler pinned in toolchain.lock.json, verifies its digest
# before extracting, and places it in a project-local ignored directory. It
# installs nothing globally and never overwrites an existing Zig installation.
#
# Exit codes: 0 ready, 1 verification or download failure, 2 usage error.

set -eu

usage() {
    cat <<'USAGE'
Usage: bootstrap.sh [options]

Prepares this checkout to build: resolves the pinned compiler, verifies its
digest, and installs it into a project-local ignored directory.

Options:
  --offline      Use only what is already cached; do not reach the network
  --check        Verify the environment and exit without downloading
  --print-path   Print the install directory on stdout and exit
  --quiet        Suppress progress output
  -h, --help     Show this message

Exit codes:
  0  ready to build
  1  verification, download, or policy failure
  2  usage error
USAGE
}

repository_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
manifest="$repository_root/toolchain.lock.json"
tool_root="$repository_root/.tools"
specification="docs/PLATFORM_SPEC.md"

offline=0
check_only=0
print_path=0
quiet=0

for argument in "$@"; do
    case "$argument" in
        --offline) offline=1 ;;
        --check) check_only=1 ;;
        --print-path) print_path=1; quiet=1 ;;
        --quiet) quiet=1 ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'bootstrap: unexpected argument %s\n' "$argument" >&2; usage >&2; exit 2 ;;
    esac
done

say() {
    [ "$quiet" -eq 1 ] || printf '%s\n' "$*"
}

fail() {
    printf 'bootstrap: %s\n' "$*" >&2
    exit 1
}

require() {
    command -v "$1" >/dev/null 2>&1 || fail "required program '$1' is not available"
}

# The specification is local-only during the private implementation stage. The
# check is repository-level, so it lives here rather than in the Zig tools.
check_specification_exclusion() {
    [ -d "$repository_root/.git" ] || return 0
    [ -f "$repository_root/$specification" ] || return 0
    command -v git >/dev/null 2>&1 || return 0

    if ! git -C "$repository_root" check-ignore -q "$specification"; then
        fail "$specification is not excluded; add /$specification to .git/info/exclude"
    fi
    # Failure of the next command is the expected success condition: the file
    # must not be tracked.
    if git -C "$repository_root" ls-files --error-unmatch "$specification" >/dev/null 2>&1; then
        fail "$specification is tracked by Git; the local-only policy forbids committing it"
    fi
    say "ok    $specification is excluded and untracked"
}

detect_target() {
    kernel=$(uname -s)
    machine=$(uname -m)
    case "$kernel" in
        Darwin) operating_system=macos ;;
        Linux) operating_system=linux ;;
        *) fail "unsupported host '$kernel'; use bootstrap.ps1 on Windows" ;;
    esac
    case "$machine" in
        arm64|aarch64) architecture=aarch64 ;;
        x86_64|amd64) architecture=x86_64 ;;
        *) fail "unsupported architecture '$machine'" ;;
    esac
    printf '%s-%s' "$architecture" "$operating_system"
}

# Reads one field of the archive entry matching the target from the manifest.
# The manifest is generated with a fixed shape, so a line-oriented read is
# sufficient and avoids depending on a JSON tool being installed.
manifest_field() {
    target=$1
    field=$2
    awk -v target="\"$target\"" -v field="\"$field\"" '
        $0 ~ "\"target\": " target { found = 1 }
        found && $0 ~ "\"" substr(field, 2, length(field) - 2) "\":" {
            line = $0
            sub(/^[^:]*:[[:space:]]*/, "", line)
            gsub(/[",]/, "", line)
            print line
            exit
        }
    ' "$manifest"
}

pinned_version() {
    awk '
        /"zig": \{/ { in_zig = 1 }
        in_zig && /"version":/ {
            line = $0
            sub(/^[^:]*:[[:space:]]*/, "", line)
            gsub(/[",]/, "", line)
            print line
            exit
        }
    ' "$manifest"
}

digest_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        fail "no SHA-256 utility available; install shasum or sha256sum"
    fi
}

[ -f "$manifest" ] || fail "missing $manifest; the toolchain is not pinned"

require awk
require uname

check_specification_exclusion

target=$(detect_target)
version=$(pinned_version)
[ -n "$version" ] || fail "could not read the pinned compiler version from $manifest"

archive_url=$(manifest_field "$target" source)
archive_digest=$(manifest_field "$target" sha256)
[ -n "$archive_url" ] || fail "no pinned archive for target '$target'"
[ -n "$archive_digest" ] || fail "no digest pinned for target '$target'"

installed="$tool_root/zig-$version-$target"

if [ "$print_path" -eq 1 ]; then
    printf '%s\n' "$installed"
    exit 0
fi

say "ok    host target $target"
say "ok    pinned compiler $version"

if [ -x "$installed/zig" ]; then
    say "ok    pinned compiler already present at $installed"
    [ "$check_only" -eq 1 ] && exit 0
    say ""
    say "Add it to PATH for this shell:"
    say "  export PATH=\"$installed:\$PATH\""
    exit 0
fi

if [ "$check_only" -eq 1 ]; then
    fail "pinned compiler is not installed; run bootstrap.sh without --check"
fi

if [ "$offline" -eq 1 ]; then
    fail "pinned compiler is not cached and --offline was requested"
fi

require tar
mkdir -p "$tool_root"
download="$tool_root/download"
mkdir -p "$download"
archive="$download/zig-$version-$target.tar.xz"

if [ ! -f "$archive" ]; then
    say "..    downloading $archive_url"
    if command -v curl >/dev/null 2>&1; then
        curl --fail --location --silent --show-error --output "$archive.partial" "$archive_url" ||
            fail "download failed"
    elif command -v wget >/dev/null 2>&1; then
        wget --quiet --output-document="$archive.partial" "$archive_url" || fail "download failed"
    else
        fail "no download utility available; install curl or wget"
    fi
    mv "$archive.partial" "$archive"
fi

observed=$(digest_of "$archive")
if [ "$observed" != "$archive_digest" ]; then
    rm -f "$archive"
    fail "digest mismatch for $target
  expected $archive_digest
  observed $observed
The archive was discarded. Nothing was installed."
fi
say "ok    digest verified"

staging="$tool_root/staging-$$"
rm -rf "$staging"
mkdir -p "$staging"
tar -xf "$archive" -C "$staging" || fail "extraction failed"

extracted=$(find "$staging" -maxdepth 1 -mindepth 1 -type d | head -n 1)
[ -n "$extracted" ] || fail "archive did not contain a compiler directory"

rm -rf "$installed"
mkdir -p "$tool_root"
mv "$extracted" "$installed"
rm -rf "$staging"

[ -x "$installed/zig" ] || fail "extracted tree has no zig executable"

say "ok    installed to $installed"
say ""
say "Add it to PATH for this shell:"
say "  export PATH=\"$installed:\$PATH\""
say ""
say "Then verify the checkout:"
say "  zig build doctor"
