#!/usr/bin/env bash
# check-docker-vulkan-gpu.sh - read-only AMD Vulkan/RADV Docker passthrough diagnostic.
#
# This script does not install packages, edit .env, or restart Docker. It only
# checks host Vulkan device nodes and whether a small container can see /dev/dri.
# Vulkan does not need /dev/kfd or ROCm userspace — it uses the RADV driver
# (Mesa) which exposes render nodes under /dev/dri.
#
# Build llama.cpp with -DGGML_VULKAN=ON (or dual-backend with -DGGML_HIP=ON)
# and serve GGUF models through the Cookbook.

set -u

PASS=0
FAIL=0
WARN=0
RENDER_GID=""
VIDEO_GID=""
TEST_IMAGE="${ODYSSEUS_VULKAN_TEST_IMAGE:-alpine:3.20}"

_pass() { printf '\033[32m[PASS]\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
_fail() { printf '\033[31m[FAIL]\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
_warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*"; WARN=$((WARN + 1)); }
_info() { printf '\033[34m[INFO]\033[0m %s\n' "$*"; }

_usage() {
    cat <<'USAGE'
Usage: scripts/check-docker-vulkan-gpu.sh

Read-only AMD Vulkan/RADV Docker GPU diagnostic. Installs nothing, edits
nothing, and does not restart Docker.

Checks:
  - host /dev/dri/renderD* exist (no /dev/kfd needed for Vulkan)
  - host render group GID for RENDER_GID in .env
  - optional host vulkaninfo visibility (RADV driver check)
  - Docker can pass /dev/dri into a small container

Environment:
  ODYSSEUS_VULKAN_TEST_IMAGE   Docker image for the passthrough smoke
                               (default: alpine:3.20)
USAGE
}

case "${1:-}" in
    --help|-h)
        _usage
        exit 0
        ;;
    "")
        ;;
    *)
        printf 'Unknown option: %s\n\n' "$1" >&2
        _usage >&2
        exit 1
        ;;
esac

_check_host_devices() {
    _info "Checking host Vulkan device nodes..."

    # Vulkan does NOT need /dev/kfd
    if [ -e /dev/kfd ]; then
        _info "/dev/kfd exists (ROCm also available — Vulkan can run alongside)"
    else
        _info "/dev/kfd not found — Vulkan/RADV path only (no ROCm kernel driver)"
    fi

    if [ -d /dev/dri ]; then
        _pass "/dev/dri exists"
    else
        _fail "/dev/dri is missing - render devices are not available."
        echo
        return 1
    fi

    render_nodes="$(find /dev/dri -maxdepth 1 -type c -name 'renderD*' -print 2>/dev/null | sort)"
    if [ -n "${render_nodes}" ]; then
        _pass "Render nodes found:"
        printf '%s\n' "${render_nodes}" | sed 's/^/        /'
    else
        _fail "No /dev/dri/renderD* node found."
        echo
        return 1
    fi
    echo
}

_check_groups() {
    _info "Checking host render/video groups..."
    RENDER_GID="$(getent group render | awk -F: '{print $3; exit}')"
    VIDEO_GID="$(getent group video | awk -F: '{print $3; exit}')"

    if [ -n "${RENDER_GID}" ]; then
        _pass "render group GID: ${RENDER_GID}"
    else
        _fail "render group not found - set RENDER_GID manually if your distro uses a different group."
    fi

    if [ -n "${VIDEO_GID}" ]; then
        _pass "video group GID: ${VIDEO_GID}"
    else
        _warn "video group not found. /dev/dri may still be enough on some hosts."
    fi
    echo
}

_check_host_vulkan() {
    _info "Checking host Vulkan/RADV driver..."

    if command -v vulkaninfo >/dev/null 2>&1; then
        vulkan_summary="$(vulkaninfo --summary 2>/dev/null || true)"
        if printf '%s\n' "${vulkan_summary}" | grep -Eq 'RADV'; then
            _pass "RADV Vulkan driver detected on host:"
            printf '%s\n' "${vulkan_summary}" \
                | grep -iE 'GPU|RADV|driver' \
                | head -12 \
                | sed 's/^/        /'
        else
            _warn "vulkaninfo exists but did not list RADV. Mesa may not include AMD Vulkan drivers."
        fi
    else
        _warn "vulkaninfo not found on PATH. This does not block Docker passthrough, but host Vulkan/RADV may be incomplete."
        _info "Install vulkan-tools (or vulkan-utils) to verify RADV: sudo apt install vulkan-tools"
    fi
    echo
}

_check_docker() {
    _info "Checking Docker..."
    if ! command -v docker >/dev/null 2>&1; then
        _fail "docker not found - install Docker first."
        echo
        return 1
    fi
    if docker info >/dev/null 2>&1; then
        _pass "Docker daemon is running."
    else
        _fail "Docker daemon is not running or this user lacks Docker permission."
        echo
        return 1
    fi
    echo
}

_check_docker_passthrough() {
    if [ -z "${RENDER_GID}" ]; then
        _fail "Skipping Docker passthrough smoke because render GID is unknown."
        echo
        return
    fi

    _info "Testing Vulkan device passthrough with ${TEST_IMAGE} (may pull on first run)..."
    group_args=(--group-add "${RENDER_GID}")
    if [ -n "${VIDEO_GID}" ]; then
        group_args+=(--group-add "${VIDEO_GID}")
    fi

    # Vulkan only needs /dev/dri — no /dev/kfd required
    if docker run --rm \
        --device=/dev/dri \
        "${group_args[@]}" \
        "${TEST_IMAGE}" \
        sh -lc 'test -d /dev/dri && ls /dev/dri/renderD* >/dev/null' \
        >/dev/null 2>&1; then
        _pass "Docker can pass /dev/dri render nodes into a container."
    else
        _fail "Docker Vulkan device passthrough failed."
        _info "Check that Docker can access /dev/dri, then retry."
    fi
    echo
}

_print_next_steps() {
    echo "=== Suggested .env values ==="
    if [ -n "${RENDER_GID}" ]; then
        printf 'COMPOSE_FILE=docker-compose.yml:docker/gpu.vulkan.yml\n'
        printf 'RENDER_GID=%s\n' "${RENDER_GID}"
    else
        printf 'COMPOSE_FILE=docker-compose.yml:docker/gpu.vulkan.yml\n'
        printf 'RENDER_GID=<numeric render group id>\n'
    fi
    echo
    echo "After restarting Odysseus, verify the slim app container sees devices:"
    echo "  docker compose exec odysseus sh -lc 'test -d /dev/dri && ls -l /dev/dri/renderD*'"
    echo
    echo "Note: Vulkan does not need /dev/kfd or ROCm userspace inside the container."
    echo "Build llama.cpp with -DGGML_VULKAN=ON (or dual-backend with -DGGML_HIP=ON)"
    echo "and serve GGUF models through the Cookbook."
}

echo "=== Odysseus AMD Vulkan Docker GPU diagnostic ==="
echo
_check_host_devices
_check_groups
_check_host_vulkan
if _check_docker; then
    _check_docker_passthrough
fi
_print_next_steps
echo
echo "=== Results: ${PASS} passed, ${WARN} warnings, ${FAIL} failed ==="
[ "${FAIL}" -eq 0 ]
