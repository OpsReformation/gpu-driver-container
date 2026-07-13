# Derived from rhel10/precompiled/Makefile for OKD / SCOS.
# Divergences: no RHSM secrets or pull-secret handling (the OKD DTK is a
# public image), KMOD_PACKAGING_BRANCH build arg, and a driver-branch alias
# tag alongside the full-version tag so the GPU operator resolves the image
# whether ClusterPolicy/NVIDIADriver "version" is set to the branch (580) or
# the full version (580.105.08).
GIT_COMMIT ?= $(shell git describe --match="" --dirty --long --always --abbrev=40 2> /dev/null || echo "")

RHEL_VERSION ?= 10
RHEL_VERSION_MAJOR = $(shell echo "${RHEL_VERSION}" | awk -F. '{print $$1}')

# NVIDIA/yum-packaging-precompiled-kmod has no rhel10 branch yet
KMOD_PACKAGING_BRANCH ?= rhel9

KERNEL_VERSION ?= ''
BUILD_ARCH ?= x86_64
TARGET_ARCH ?= $(shell echo "${BUILD_ARCH}" | sed "s/+64k//")

KERNEL_VERSION_NOARCH=$(shell echo "${KERNEL_VERSION}" | sed "s/\.${TARGET_ARCH}//")
KERNEL_VERSION_TAG = $(shell echo "${KERNEL_VERSION_NOARCH}.${BUILD_ARCH}" | sed "s/+/_/")
BASE_URL ?= https://us.download.nvidia.com/tesla

CUDA_VERSION ?= 13.0.1
CUDA_DIST = ubi${RHEL_VERSION_MAJOR}

DRIVER_VERSION ?= ''
DRIVER_BRANCH = $(shell echo "${DRIVER_VERSION}" | awk -F. '{print $$1}')
DRIVER_TYPE ?= passthrough
DRIVER_OPEN ?= false
DRIVER_STREAM_TYPE ?= ''

# Must match the OS tag the GPU operator computes for the cluster's nodes
# (node os-release ID + major version; centos10 on SCOS 10 nodes)
OS_TAG ?= centos10

# e.g. quay.io/okd/scos-content@sha256:... — resolve per OKD release with:
#   oc adm release info <release-image> --image-for=driver-toolkit
DRIVER_TOOLKIT_IMAGE ?= ''

CONTAINER_TOOL ?= docker
DOCKERFILE ?= Dockerfile

IMAGE_REGISTRY ?= ghcr.io/opsreformation
ifeq ($(DRIVER_TYPE),vgpu)
	IMAGE_NAME ?= vgpu-guest-driver
else
	IMAGE_NAME ?= driver
endif

BUILDER_USER ?= $(shell git config --get user.name)
BUILDER_EMAIL ?= $(shell git config --get user.email)

.PHONY: image image-push

# Build the image
image:
	@echo "!=== Building image ${IMAGE_REGISTRY}/${IMAGE_NAME}:${DRIVER_VERSION}-${KERNEL_VERSION_TAG}-${OS_TAG} ===!"
	${CONTAINER_TOOL} build \
		--platform linux/${shell echo "${TARGET_ARCH}" | sed "s/x86_64/amd64/;s/aarch64/arm64/"} \
		--build-arg RHEL_VERSION=${RHEL_VERSION} \
		--build-arg KMOD_PACKAGING_BRANCH=${KMOD_PACKAGING_BRANCH} \
		--build-arg CUDA_VERSION=${CUDA_VERSION} \
		--build-arg CUDA_DIST=${CUDA_DIST} \
		--build-arg BUILD_ARCH=${BUILD_ARCH} \
		--build-arg TARGET_ARCH=${TARGET_ARCH} \
		--build-arg KERNEL_VERSION=${KERNEL_VERSION} \
		--build-arg KERNEL_VERSION_NOARCH=${KERNEL_VERSION_NOARCH} \
		--build-arg DRIVER_VERSION=${DRIVER_VERSION} \
		--build-arg DRIVER_EPOCH=${DRIVER_EPOCH} \
		--build-arg BUILDER_USER="${BUILDER_USER}" \
		--build-arg BUILDER_EMAIL=${BUILDER_EMAIL} \
		--build-arg DRIVER_TOOLKIT_IMAGE=${DRIVER_TOOLKIT_IMAGE} \
		--build-arg DRIVER_OPEN=${DRIVER_OPEN} \
		--build-arg DRIVER_TYPE=${DRIVER_TYPE} \
		--build-arg DRIVER_STREAM_TYPE=${DRIVER_STREAM_TYPE} \
		--build-arg BASE_URL=${BASE_URL} \
		--build-arg OS_TAG=${OS_TAG} \
		--build-arg GIT_COMMIT=${GIT_COMMIT} \
		--tag ${IMAGE_REGISTRY}/${IMAGE_NAME}:${DRIVER_VERSION}-${KERNEL_VERSION_TAG}-${OS_TAG} \
		--tag ${IMAGE_REGISTRY}/${IMAGE_NAME}:${DRIVER_BRANCH}-${KERNEL_VERSION_TAG}-${OS_TAG} \
		--progress=plain \
		--file ${DOCKERFILE} .

image-push:
	@echo "!=== Pushing image ===!"
	${CONTAINER_TOOL} push \
		${IMAGE_REGISTRY}/${IMAGE_NAME}:${DRIVER_VERSION}-${KERNEL_VERSION_TAG}-${OS_TAG}
	${CONTAINER_TOOL} push \
		${IMAGE_REGISTRY}/${IMAGE_NAME}:${DRIVER_BRANCH}-${KERNEL_VERSION_TAG}-${OS_TAG}
