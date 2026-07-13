# Precompiled NVIDIA GPU driver container image for OKD (SCOS)

Builds a precompiled NVIDIA driver container for OKD clusters running
CentOS Stream CoreOS (SCOS). Neither NVIDIA nor Red Hat publishes driver
images for SCOS (`nvcr.io/nvidia/driver` only has `-rhcos4.x` tags, and the
driver build scripts reject SCOS as a distribution — see
[gpu-driver-container#301](https://github.com/NVIDIA/gpu-driver-container/issues/301)),
so this flavor adapts NVIDIA's official
[precompiled driver process](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/precompiled-drivers.html)
using the OKD Driver Toolkit as the build environment.

This directory is a copy of `rhel10/precompiled` with SCOS-specific changes;
see the comment block at the top of the [Dockerfile](Dockerfile) for the
list of intentional divergences. When syncing with upstream, diff this
directory against `rhel10/precompiled` and port relevant changes.

**Prerequisites** (compare with the RHEL flavor: no Red Hat subscription,
no activation key, no OpenShift pull secret):

* Docker with buildx (an amd64 build host or CI runner is strongly
  recommended; kernel module compilation under emulation is slow and rpm
  is known to segfault under qemu/Rosetta)
* Access to `quay.io/okd` (public) and `nvcr.io/nvidia/cuda` (public)

## Image build

### CI (canonical)

The [`build-scos-precompiled`](../../.github/workflows/build-scos-precompiled.yml)
workflow resolves everything from an OKD release: it extracts the
driver-toolkit image reference from the release payload
(`quay.io/okd/scos-release:<version>`), reads the kernel version from the
DTK's `/etc/driver-toolkit-release.json`, builds, smoke-tests, scans, and
pushes to `ghcr.io/opsreformation/driver`.

Run it via workflow dispatch with the target OKD release and driver version
**before upgrading the cluster**, so the driver image for the new kernel
exists when nodes reboot into it.

OKD DTKs sometimes lag the release's actual node kernel (e.g.
4.21.0-okd-scos.11 ships a DTK built for kernel `-213` while its nodes run
`-219`). When that happens, pass the node kernel (`uname -r` /
`oc get nodes -o wide`) via the `kernel_version` dispatch input — the
Dockerfile detects the missing headers and installs the matching
kernel-devel from CentOS Stream koji, which retains all kernel builds
after the Stream mirrors rotate.

### Local

```
./build-scos-driver.sh --okd-version 4.21.0-okd-scos.11 \
    --kernel-version $(oc get nodes -o jsonpath='{.items[0].status.nodeInfo.kernelVersion}') \
    --driver-version 580.126.20 --load
```

Or with the Makefile, mirroring the upstream flavors:

```
export DRIVER_TOOLKIT_IMAGE=$( \
    oc adm release info --image-for=driver-toolkit \
    quay.io/okd/scos-release:4.21.0-okd-scos.11 \
)
# Prefer the node kernel over the DTK's when they differ
export KERNEL_VERSION=$(oc get nodes -o jsonpath='{.items[0].status.nodeInfo.kernelVersion}')
export DRIVER_VERSION=580.126.20
export DRIVER_EPOCH=1
export OS_TAG=centos10

make image image-push
```

Notes:

* `OS_TAG` must match the OS tag the GPU operator computes for the
  cluster's nodes: os-release ID + major version, which is `centos10` on
  SCOS 10 nodes (verified against a live OKD 4.21 cluster). Confirm
  against the image the driver daemonset actually tries to pull.
* The driver version must exist both as a Tesla runfile
  (`https://us.download.nvidia.com/tesla/<version>/`) and as userspace RPMs
  in the [rhel10 CUDA repo](https://developer.download.nvidia.com/compute/cuda/repos/rhel10/x86_64/).
* Secure Boot: as with the upstream flavors, place `private_key.priv` and
  `public_key.der` in this directory to sign modules with a trusted key;
  otherwise a throwaway self-signed key is generated.

## NVIDIA GPU operator

The image tag follows the upstream precompiled format
`${DRIVER_VERSION}-${KERNEL_VERSION}-${OS_TAG}`, e.g.
`ghcr.io/opsreformation/driver:580.126.20-6.12.0-219.el10.x86_64-centos10`.
A driver-branch alias (`580-...`) is pushed alongside it.

Define the `NVIDIADriver` custom resource to use the precompiled image:

```
  spec:
    usePrecompiled: true
    repository: ghcr.io/opsreformation
    image: driver
    version: 580.126.20
```

And enable the CRD in the `ClusterPolicy` (note
`use_ocp_driver_toolkit: false` — the on-cluster DTK build path is broken
on OKD and unnecessary with precompiled images):

```
    operator:
      use_ocp_driver_toolkit: false
    driver:
      enabled: true
      useNvidiaDriverCRD: true
    validator:
      driver:
        env:
          - name: DISABLE_DEV_CHAR_SYMLINK_CREATION
            value: "true"
```

Full examples: [nvidiadriver.json](nvidiadriver.json) and
[clusterpolicy.json](clusterpolicy.json).

## Cluster upgrades

Precompiled drivers are pinned to one kernel. The operational rule: when an
OKD upgrade is planned, dispatch the workflow with the new release version
first, and only start the upgrade once the driver image for the new kernel
is in the registry. The operator's daemonset resolves the image by node
kernel version and will pick up the new image as nodes reboot.
