#!/usr/bin/env sh
# Installs the pinned Mesa lavapipe, the software Vulkan implementation the correctness lane
# renders against, and verifies it against the pin.
#
# Lavapipe is good for pixel-conformance gates precisely because it is deterministic — but only
# if it does not float. An `apt install mesa-vulkan-drivers` tracks whatever the distro ships
# that day, so a silent Mesa update could shift a rendered pixel and rewrite what "conformant"
# means. This installs on the pinned runner image and then verifies the exact library: the
# SHA-256 of the installed lavapipe ICD must equal the digest recorded in
# infrastructure/ci/vulkan-runtime.lock.json. A mismatch fails the gate, so a Mesa change is a
# deliberate re-pin after re-verifying conformance, never a silent shift.
#
# On the first run for a pinned image the lock carries a PENDING sentinel: the script prints the
# resolved version and digest and fails, so the pin is recorded by a human commit — the same
# resolve-then-lock discipline as the toolchain manifest — rather than trusted on faith.
#
# When the real-GPU performance lane is added, this lane stays: lavapipe remains the
# deterministic correctness lane, and hardware runs performance plus a software-vs-hardware
# parity check against the same vectors.
#
# Exit codes: 0 the installed implementation matches the pin, 1 unresolved pin or drift.

set -eu

repository_root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repository_root"

lock='infrastructure/ci/vulkan-runtime.lock.json'
field() { sed -n "s/.*\"$1\": \"\\([^\"]*\\)\".*/\\1/p" "$lock" | head -1; }

pinned_version=$(field version)
pinned_sha=$(field sha256)
library=$(field library)

# Recommends are installed too: lavapipe needs its full runtime (the LLVM library it JITs
# through), and omitting it leaves an ICD that loads but cannot create a device.
sudo apt-get update
sudo apt-get install -y mesa-vulkan-drivers libvulkan1 vulkan-tools

installed_version=$(dpkg-query -W -f='${Version}' mesa-vulkan-drivers)
[ -f "$library" ] || {
    echo "provision-lavapipe: the lavapipe library $library is not present after install" >&2
    exit 1
}
installed_sha=$(sha256sum "$library" | cut -d' ' -f1)

# Discover the lavapipe ICD manifest: the JSON the loader reads that points at the pinned
# library. The library is the determinism anchor and is digest-pinned; the manifest is only the
# pointer, and its filename varies by Mesa build, so it is found by content rather than guessed.
icd=$(grep -rl "$(basename "$library")" /usr/share/vulkan/icd.d/ 2>/dev/null | head -1 || true)
if [ -z "$icd" ]; then
    echo "provision-lavapipe: no ICD manifest referencing $(basename "$library") in /usr/share/vulkan/icd.d/" >&2
    ls -la /usr/share/vulkan/icd.d/ >&2 2>/dev/null || true
    exit 1
fi
echo "provision-lavapipe: ICD manifest ${icd}"

echo "provision-lavapipe: mesa-vulkan-drivers ${installed_version}"
echo "provision-lavapipe: ${library} sha256 ${installed_sha}"

if [ "$pinned_sha" = 'PENDING-FIRST-RESOLUTION' ]; then
    echo "provision-lavapipe: the pin is unresolved. Record these in ${lock} and re-run:" >&2
    echo "    \"version\": \"${installed_version}\"," >&2
    echo "    \"sha256\": \"${installed_sha}\"" >&2
    exit 1
fi

if [ "$installed_version" != "$pinned_version" ]; then
    echo "provision-lavapipe: mesa version ${installed_version} does not match the pin ${pinned_version}" >&2
    exit 1
fi
if [ "$installed_sha" != "$pinned_sha" ]; then
    echo "provision-lavapipe: the lavapipe library digest changed — re-verify pixel conformance and re-pin, do not float" >&2
    exit 1
fi

# Confirm the implementation actually works, not just that its files are present: lavapipe
# must enumerate a device through the loader. This catches a broken install here rather than
# deep in the test suite, and proves the lane the device tests are about to trust.
if ! VK_ICD_FILENAMES="$icd" vulkaninfo --summary >/tmp/vulkaninfo.txt 2>&1 || ! grep -qi 'llvmpipe' /tmp/vulkaninfo.txt; then
    echo 'provision-lavapipe: lavapipe did not enumerate a device' >&2
    sed -n '1,40p' /tmp/vulkaninfo.txt >&2
    exit 1
fi
echo "provision-lavapipe: lavapipe presents $(grep -i -m1 'deviceName' /tmp/vulkaninfo.txt | sed 's/^[[:space:]]*//')"

# Verified: point the loader at lavapipe and make the device tests strict on this lane.
echo "VK_ICD_FILENAMES=${icd}" >> "$GITHUB_ENV"
echo "REQUIRE_VULKAN_DEVICE=1" >> "$GITHUB_ENV"
echo 'provision-lavapipe: pinned lavapipe verified'
