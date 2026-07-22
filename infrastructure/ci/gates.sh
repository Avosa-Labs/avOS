#!/usr/bin/env sh
# Runs every gate that must be green before a change is committed or merged.
#
# The gates live here rather than in a provider's workflow file so that a
# contributor runs exactly what continuous integration runs, and so that
# changing provider does not change the definition of "green".
#
# Exit codes: 0 all gates passed, 1 at least one gate failed, 2 usage error.

set -eu

usage() {
    cat <<'USAGE'
Usage: gates.sh [options]

Runs the full gate set: formatting, build, unit tests, brand neutrality under
both the configured and the synthetic brand, toolchain health, and pin
verification.

Options:
  --offline      Skip gates that require network access
  --list         Print the gate names and exit
  -h, --help     Show this message

Exit codes:
  0  every gate passed
  1  at least one gate failed
  2  usage error
USAGE
}

repository_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
reference_brand="brand/reference/brand.json"

offline=0

for argument in "$@"; do
    case "$argument" in
        --offline) offline=1 ;;
        --list)
            printf '%s\n' \
                'format-check' \
                'build' \
                'test' \
                'test (synthetic brand)' \
                'brand-check' \
                'brand-check (synthetic brand)' \
                'doctor' \
                'version-lock --verify (network)'
            exit 0
            ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'gates: unexpected argument %s\n' "$argument" >&2; usage >&2; exit 2 ;;
    esac
done

cd "$repository_root"

command -v zig >/dev/null 2>&1 || {
    printf 'gates: zig is not on PATH; run tools/bootstrap/bootstrap.sh first\n' >&2
    exit 1
}

failed=0

run_gate() {
    name=$1
    shift
    printf '\n=== %s ===\n' "$name"
    if "$@"; then
        printf 'PASS  %s\n' "$name"
    else
        printf 'FAIL  %s\n' "$name"
        failed=$((failed + 1))
    fi
}

run_gate 'format-check' zig build format-check
run_gate 'build' zig build
run_gate 'test' zig build test
run_gate 'test (synthetic brand)' zig build test "-Dbrand=$reference_brand"
run_gate 'source-tracked' "$repository_root/infrastructure/ci/source-tracked.sh"
run_gate 'convention-check' zig build convention-check
run_gate 'brand-check' zig build brand-check
run_gate 'brand-check (synthetic brand)' zig build brand-check "-Dbrand=$reference_brand"
run_gate 'simulator (canonical demo)' zig build simulator -- --no-ledger
# Some checks need a reference device, which needs KVM on Linux. A host that
# cannot run them reports each by name as skipped: an absent gate that printed
# nothing would eventually be read as a passing one.
report_device_gates() {
    if [ -e /dev/kvm ]; then
        return 1
    fi
    printf '\n=== reference device checks ===\n'
    for check in \
        'reference device boots from the pinned build' \
        'supported application installs and launches' \
        'application capability call reaches the bridge' \
        'unauthorized host capability request denied at the boundary' \
        'runtime fault leaves the shell unaffected'
    do
        printf 'SKIP  %s (no KVM on this host)\n' "$check"
    done
    return 0
}

report_device_gates || true

run_gate 'doctor' zig build doctor

if [ "$offline" -eq 0 ]; then
    # Confirms the committed pins still match what the official sources publish.
    # Skipped offline because it is the one gate that must reach the network.
    run_gate 'version-lock --verify' zig build version-lock -- --verify
else
    printf '\n=== version-lock --verify ===\nSKIP  offline\n'
fi

printf '\n'
if [ "$failed" -eq 0 ]; then
    printf 'gates: all gates passed\n'
    exit 0
fi
printf 'gates: %d gate(s) failed\n' "$failed"
exit 1
