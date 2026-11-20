#!/bin/bash
# Fallback for when GitHub's Linux runners are unavailable: build the Linux release archives
# (x86_64 and aarch64) locally, in rockylinux:9 containers with podman (or docker), with the same
# script as the release workflow (release/linux-build.sh), and optionally add them to the GitHub
# release. See "Making a release" in README.md.
#
# Usage: release/linux-local.sh [--upload] [TAG]
#   TAG: osmesa-mesa-<mesa version>-llvm-<llvm version> (default: the versions in release.yml). The
#        sources are "git archive TAG" (or HEAD if the tag doesn't exist yet and --upload isn't given;
#        REV=<commit> for a test build of another commit).
#   --upload: add the archives, with ARCHIVE.sha256, to the release TAG with gh (see
#        release/publish.sh and release/finalize.sh), and make it a full release if every platform is
#        there. Architectures already in the release (built on GitHub) are skipped. The local tag must
#        be GitHub's. Without it, the archives are only left in $WORK/out.
#
# Each architecture is built in its own throwaway container (--rm), one at a time; the container
# needs network access (dnf, pip). The architecture that isn't the host's runs under emulation
# (binfmt): with qemu (podman machine's default on Apple Silicon; qemu-user-static on Linux) LLVM
# takes hours, with Rosetta (podman machine with Rosetta enabled, or OrbStack) it is much faster.
# The container engine (e.g. podman machine) needs at least CPUS CPUs, MEMORY_GB of memory, and
# MIN_FREE_GB of free space in its storage: this is checked before each build.
#
# Host requirements: podman (or CONTAINER=docker), git, curl, and gh for --upload.
# Environment: WORK (/tmp/osmesa-linux-local, must not be in ~/Documents), ARCHS ("aarch64 x86_64"),
# CONTAINER (podman), IMAGE (docker.io/library/rockylinux:9, pulled if newer), CPUS (4), MEMORY_GB
# (6), MKJOBS (4), MAX_LOAD (number of CPUs: each build waits until the host load average is below
# it), MIN_FREE_GB (30: and until the container storage has that much free space), WAIT_IDLE (1: and
# until no other container is running, for at most WAIT_IDLE_HOURS, 4).

OS=linux
DEFAULT_ARCHS="aarch64 x86_64"
DEFAULT_WORK=/tmp/osmesa-linux-local
# shellcheck source=release/common.sh
. "$(dirname "$0")/common.sh"
init "$@"
CONTAINER=${CONTAINER:-podman}
IMAGE=${IMAGE:-docker.io/library/rockylinux:9}
CPUS=${CPUS:-4}
MEMORY_GB=${MEMORY_GB:-6}
MKJOBS=${MKJOBS:-4}
# podman: pull the image if a newer one exists; docker has no "newer"
PULL=newer; [ "$CONTAINER" = podman ] || PULL=always

command -v "$CONTAINER" >/dev/null || die "$CONTAINER not found"
resolve_source
skip_published
prepare_sources

# what a container of this architecture sees: CPUs, memory (GB) and free space in its storage (GB)
probe() { # platform
    # label=disable: SELinux hosts would deny access to the shared directory (podman and docker)
    # shellcheck disable=SC2016 # expanded in the container
    "$CONTAINER" run --rm --pull="$PULL" --platform "$1" --security-opt label=disable "$IMAGE" \
        sh -c 'echo "$(nproc) $(awk "/MemTotal/ {print int(\$2 / 1048576)}" /proc/meminfo) $(df -Pk / | awk "NR==2 {print int(\$4 / 1048576)}")"'
}
probe_free() { # platform
    probe "$1" | awk '{print $3}'
}

# one container at a time, started only when the host isn't overloaded
for arch in $ARCHS; do
    case "$arch" in aarch64) platform=linux/arm64;; x86_64) platform=linux/amd64;; *) die "unknown arch $arch";; esac
    # podman machine's memory is shared with other containers: wait until none is running
    waited=0
    while [ "${WAIT_IDLE:-1}" = 1 ] && [ -n "$("$CONTAINER" ps -q)" ]; do
        [ "$waited" -ge $((${WAIT_IDLE_HOURS:-4} * 3600)) ] && die "other containers are still running (WAIT_IDLE=0 to skip)"
        log "other containers are running ($("$CONTAINER" ps --format '{{.Names}}' | tr '\n' ' ')), waiting (WAIT_IDLE=0 to skip)"
        sleep 120; waited=$((waited + 120))
    done
    read -r ncpu memgb freegb <<EOF
$(probe "$platform")
EOF
    log "$arch: the container sees $ncpu CPUs, $memgb GB of memory, $freegb GB free"
    [ "$ncpu" -ge "$CPUS" ] || die "the container engine has $ncpu CPUs, $CPUS needed (e.g. podman machine set --cpus $CPUS, or CPUS=$ncpu)"
    [ "$memgb" -ge "$MEMORY_GB" ] || die "the container engine has $memgb GB of memory, $MEMORY_GB needed (e.g. podman machine set --memory 8192)"
    wait_for_host -c probe_free "$platform"
    name="osmesa-install-$tag-linux-$arch"
    log "$arch: building in a $IMAGE container ($platform; log: $WORK/out/build-$arch.log)"
    # the build runs in the container's own filesystem; only the sources, the tarballs and the
    # output are on the shared directory
    # shellcheck disable=SC2016 # expanded in the container
    "$CONTAINER" run --rm --platform "$platform" --security-opt label=disable \
        --cpus "$CPUS" --memory "${MEMORY_GB}g" -v "$WORK:/host" \
        -e CI_MESA_VERSION="$mesaversion" -e CI_LLVM_VERSION="$llvmversion" \
        -e MKJOBS="$MKJOBS" -e NAME="$name" -e ARCH="$arch" \
        -e BUILDINFO="$CONTAINER $platform on $(uname -s) $(uname -m), osmesa-install $commit (release/linux-local.sh)" \
        "$IMAGE" bash -c '
            set -eu
            cp -R /host/src /root/w && cd /root/w
            mkdir -p build && cp /host/dl/* build/
            echo "arch: $(uname -m)"
            bash release/linux-build.sh deps
            bash release/linux-build.sh osmesa
            bash release/linux-build.sh check "$ARCH"
            bash release/linux-build.sh package "$NAME" "$ARCH"
            bash release/linux-build.sh test-cmake "$NAME"
            bash release/linux-build.sh test-pkgconfig "$NAME"
            cp "out/$NAME.tar.xz" /host/out/
            echo "container build $ARCH: OK"' > "$WORK/out/build-$arch.log" 2>&1 \
        || die "$arch build failed, see $WORK/out/build-$arch.log"
    tail -n 1 "$WORK/out/build-$arch.log"
done
ls -la "$WORK"/out/*.tar.xz

publish_archives linux-local.sh
