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

# Reads one field of a component's archive entry for the given target.
component_field() {
    component=$1
    target=$2
    field=$3
    awk -v component="\"$component\"" -v target="\"$target\"" -v field="$field" '
        $0 ~ "\"name\": " component { in_component = 1 }
        in_component && $0 ~ "\"target\": " target { found = 1 }
        found && $0 ~ "\"" field "\":" {
            line = $0
            sub(/^[^:]*:[[:space:]]*/, "", line)
            gsub(/[",]/, "", line)
            print line
            exit
        }
    ' "$manifest"
}

component_version() {
    awk -v component="\"$1\"" '
        $0 ~ "\"name\": " component { in_component = 1 }
        in_component && $0 ~ "\"version\":" {
            line = $0
            sub(/^[^:]*:[[:space:]]*/, "", line)
            gsub(/[",]/, "", line)
            print line
            exit
        }
    ' "$manifest"
}

# Fetches, verifies, and extracts one pinned component.
install_component() {
    name=$1
    component_target=$2
    version=$(component_version "$name")
    [ -n "$version" ] || return 0

    destination="$tool_root/$name-$version"
    if [ -d "$destination" ]; then
        say "ok    $name $version already present"
        return 0
    fi

    url=$(component_field "$name" "$component_target" source)
    digest=$(component_field "$name" "$component_target" sha256)
    if [ -z "$url" ] || [ -z "$digest" ]; then
        say "note  $name is not pinned for $component_target; skipping"
        return 0
    fi

    [ "$offline" -eq 1 ] && fail "$name is not cached and --offline was requested"

    case "$url" in
        *.zip) suffix=zip ;;
        *) suffix=tar.xz ;;
    esac
    component_archive="$download/$name-$version-$component_target.$suffix"

    if [ ! -f "$component_archive" ]; then
        say "..    downloading $url"
        if command -v curl >/dev/null 2>&1; then
            curl --fail --location --silent --show-error --output "$component_archive.partial" "$url" ||
                fail "download failed"
        else
            wget --quiet --output-document="$component_archive.partial" "$url" || fail "download failed"
        fi
        mv "$component_archive.partial" "$component_archive"
    fi

    observed_digest=$(digest_of "$component_archive")
    if [ "$observed_digest" != "$digest" ]; then
        rm -f "$component_archive"
        fail "digest mismatch for $name
  expected $digest
  observed $observed_digest
The archive was discarded. Nothing was installed."
    fi
    say "ok    $name $version digest verified"

    component_staging="$tool_root/staging-$name-$$"
    rm -rf "$component_staging" && mkdir -p "$component_staging"
    tar -xf "$component_archive" -C "$component_staging" || fail "extraction failed"
    component_extracted=$(find "$component_staging" -maxdepth 1 -mindepth 1 -type d | head -n 1)
    [ -n "$component_extracted" ] || fail "$name archive contained no directory"
    mv "$component_extracted" "$destination"
    rm -rf "$component_staging"
    say "ok    $name installed to $destination"
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

require tar
mkdir -p "$tool_root"
download="$tool_root/download"
mkdir -p "$download"
archive="$download/zig-$version-$target.tar.xz"

compiler_present=0
[ -x "$installed/zig" ] && compiler_present=1

if [ "$compiler_present" -eq 1 ]; then
    say "ok    pinned compiler already present at $installed"
elif [ "$check_only" -eq 1 ]; then
    fail "pinned compiler is not installed; run bootstrap.sh without --check"
elif [ "$offline" -eq 1 ]; then
    fail "pinned compiler is not cached and --offline was requested"
fi

if [ "$compiler_present" -eq 0 ] && [ ! -f "$archive" ]; then
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

if [ "$compiler_present" -eq 0 ]; then
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
fi

# Components are pinned in the same manifest and verified the same way. A
# component not pinned for this target is skipped rather than fatal, so a host
# without one still gets a working checkout.
install_component wasmtime "$target"

say ""
say "Add it to PATH for this shell:"
say "  export PATH=\"$installed:\$PATH\""
say ""
say "Then verify the checkout:"
say "  zig build doctor"
