#!/bin/bash
# Build script for the OKD/SCOS precompiled NVIDIA driver container.
# Repurposed from CephaloProxy's container/build-multiplatform.sh to keep
# tooling consistent across OpsReformation repos.
#
# The driver image is amd64-only: it embeds kernel modules compiled against
# the x86_64 SCOS kernel of a specific OKD release, and the OKD driver
# toolkit (DTK) image is published for x86_64 only.
#
# Usage:
#   ./build-scos-driver.sh [OPTIONS]
#
# Options:
#   --okd-version VERSION   OKD release, e.g. 4.21.0-okd-scos.11. Used to
#                           resolve the DTK image and kernel version, and to
#                           derive the OS tag (scos4.21)
#   --dtk-image IMAGE       Driver toolkit image (overrides --okd-version
#                           resolution)
#   --kernel-version KVER   Target kernel, e.g. 6.12.0-213.el10.x86_64
#                           (default: read from the DTK image)
#   --driver-version VER    NVIDIA driver version, e.g. 580.105.08 (required)
#   --cuda-version VER      CUDA version for the base image (default: 13.0.1)
#   --os-tag TAG            OS tag suffix, e.g. scos4.21 (default: derived
#                           from --okd-version)
#   --registry REGISTRY     Container registry URL (default: ghcr.io/opsreformation)
#   --image IMAGE           Image name (default: driver)
#   --tag TAG               Image tag (default: <driver>-<kernel>-<os-tag>)
#   --push                  Push to registry after build
#   --load                  Load image into local Docker
#
# Examples:
#   # Build for the current cluster release and load locally
#   ./build-scos-driver.sh --okd-version 4.21.0-okd-scos.11 \
#       --driver-version 580.105.08 --load
#
#   # Build and push to ghcr
#   ./build-scos-driver.sh --okd-version 4.21.0-okd-scos.11 \
#       --driver-version 580.105.08 --push

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default values
OKD_VERSION=""
DTK_IMAGE=""
KERNEL_VERSION=""
DRIVER_VERSION=""
CUDA_VERSION="13.0.1"
OS_TAG=""
REGISTRY="ghcr.io/opsreformation"
IMAGE_NAME="driver"
TAG=""
PUSH=""
LOAD=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --okd-version)
            OKD_VERSION="$2"
            shift 2
            ;;
        --dtk-image)
            DTK_IMAGE="$2"
            shift 2
            ;;
        --kernel-version)
            KERNEL_VERSION="$2"
            shift 2
            ;;
        --driver-version)
            DRIVER_VERSION="$2"
            shift 2
            ;;
        --cuda-version)
            CUDA_VERSION="$2"
            shift 2
            ;;
        --os-tag)
            OS_TAG="$2"
            shift 2
            ;;
        --registry)
            REGISTRY="$2"
            shift 2
            ;;
        --image)
            IMAGE_NAME="$2"
            shift 2
            ;;
        --tag)
            TAG="$2"
            shift 2
            ;;
        --push)
            PUSH="true"
            shift
            ;;
        --load)
            LOAD="true"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 --driver-version VER [--okd-version VER | --dtk-image IMG] [OPTIONS]"
            exit 1
            ;;
    esac
done

# Validate options
if [[ -z "$DRIVER_VERSION" ]]; then
    echo "Error: --driver-version is required (e.g. 580.105.08)"
    exit 1
fi

if [[ -z "$DTK_IMAGE" && -z "$OKD_VERSION" ]]; then
    echo "Error: either --okd-version or --dtk-image is required"
    exit 1
fi

if [[ -n "$PUSH" && -n "$LOAD" ]]; then
    echo "Error: Cannot use --push and --load together"
    exit 1
fi

# Resolve the DTK image from the OKD release payload
if [[ -z "$DTK_IMAGE" ]]; then
    RELEASE_IMAGE="quay.io/okd/scos-release:${OKD_VERSION}"
    echo "Resolving driver-toolkit image from ${RELEASE_IMAGE}..."
    cid=$(docker create --platform linux/amd64 "$RELEASE_IMAGE" placeholder)
    trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT
    docker cp "$cid:/release-manifests/image-references" /tmp/okd-image-references
    docker rm "$cid" >/dev/null
    trap - EXIT
    DTK_IMAGE=$(python3 -c '
import json
with open("/tmp/okd-image-references") as f:
    refs = json.load(f)
print(next(t["from"]["name"] for t in refs["spec"]["tags"] if t["name"] == "driver-toolkit"))
')
    echo "Driver toolkit image: ${DTK_IMAGE}"
fi

# Read the kernel version from the DTK image
if [[ -z "$KERNEL_VERSION" ]]; then
    echo "Reading kernel version from the driver toolkit image..."
    KERNEL_VERSION=$(docker run --rm --platform linux/amd64 "$DTK_IMAGE" \
        cat /etc/driver-toolkit-release.json | python3 -c 'import json,sys; print(json.load(sys.stdin)["KERNEL_VERSION"])')
    echo "Kernel version: ${KERNEL_VERSION}"
fi

# Derive the OS tag (4.21.0-okd-scos.11 -> scos4.21)
if [[ -z "$OS_TAG" ]]; then
    if [[ -z "$OKD_VERSION" ]]; then
        echo "Error: --os-tag is required when --okd-version is not given"
        exit 1
    fi
    OS_TAG="scos$(echo "$OKD_VERSION" | cut -d. -f1-2)"
fi

DRIVER_BRANCH="${DRIVER_VERSION%%.*}"
KERNEL_VERSION_NOARCH="${KERNEL_VERSION%.x86_64}"

if [[ -z "$TAG" ]]; then
    TAG="${DRIVER_VERSION}-${KERNEL_VERSION}-${OS_TAG}"
fi
BRANCH_TAG="${DRIVER_BRANCH}-${KERNEL_VERSION}-${OS_TAG}"

FULL_IMAGE_NAME="${REGISTRY}/${IMAGE_NAME}:${TAG}"
BRANCH_IMAGE_NAME="${REGISTRY}/${IMAGE_NAME}:${BRANCH_TAG}"

# Create buildx builder if it doesn't exist
if ! docker buildx ls | grep -q gpu-driver-builder; then
    echo "Creating buildx builder: gpu-driver-builder"
    docker buildx create --name gpu-driver-builder --use
fi

# Ensure builder is running
docker buildx inspect --bootstrap

OUTPUT_ARGS=""
if [[ -n "$PUSH" ]]; then
    OUTPUT_ARGS="--push"
elif [[ -n "$LOAD" ]]; then
    OUTPUT_ARGS="--load"
fi

echo "Building OKD/SCOS precompiled NVIDIA driver container..."
echo "Driver: ${DRIVER_VERSION} (branch ${DRIVER_BRANCH})"
echo "Kernel: ${KERNEL_VERSION}"
echo "Image:  ${FULL_IMAGE_NAME}"
echo "Alias:  ${BRANCH_IMAGE_NAME}"
echo ""

docker buildx build \
    --platform linux/amd64 \
    --file "${SCRIPT_DIR}/Dockerfile" \
    --build-arg DRIVER_TOOLKIT_IMAGE="${DTK_IMAGE}" \
    --build-arg RHEL_VERSION=10 \
    --build-arg CUDA_VERSION="${CUDA_VERSION}" \
    --build-arg CUDA_DIST=ubi10 \
    --build-arg BUILD_ARCH=x86_64 \
    --build-arg TARGET_ARCH=x86_64 \
    --build-arg KERNEL_VERSION="${KERNEL_VERSION}" \
    --build-arg KERNEL_VERSION_NOARCH="${KERNEL_VERSION_NOARCH}" \
    --build-arg DRIVER_VERSION="${DRIVER_VERSION}" \
    --build-arg DRIVER_EPOCH="${DRIVER_EPOCH:-1}" \
    --build-arg OS_TAG="${OS_TAG}" \
    --build-arg BUILDER_USER="${BUILDER_USER:-$(git config --get user.name || echo builder)}" \
    --build-arg BUILDER_EMAIL="${BUILDER_EMAIL:-$(git config --get user.email || echo builder@localhost)}" \
    --tag "${FULL_IMAGE_NAME}" \
    --tag "${BRANCH_IMAGE_NAME}" \
    ${OUTPUT_ARGS} \
    "${SCRIPT_DIR}"

echo ""
echo "Build complete!"

if [[ -n "$LOAD" ]]; then
    echo "Image loaded into local Docker: ${FULL_IMAGE_NAME}"
elif [[ -n "$PUSH" ]]; then
    echo "Image pushed to registry: ${FULL_IMAGE_NAME} (and ${BRANCH_IMAGE_NAME})"
else
    echo "Image built but not loaded or pushed"
    echo "Use --load to load into local Docker or --push to push to registry"
fi
