#!/usr/bin/env bash

set -exuo pipefail -o noclobber

CWD=$(pwd)
KERNEL_VAR_FILE=${CWD}/kernel-vars

if [ ! -f "${KERNEL_VAR_FILE}" ]; then
    echo "Kernel variable file '${KERNEL_VAR_FILE}' does not exist, run ./build_kernel.sh first"
    exit 1
fi

. "${KERNEL_VAR_FILE}"

cd "${CWD}"

DRIVER_VERSION=5.4
DRIVER_VERSION_EXTRA=-1.0.3.0
DRIVER_PACKAGE_NAME=MLNX_EN
DRIVER_DIR=${DRIVER_PACKAGE_NAME}_SRC-${DRIVER_VERSION}${DRIVER_VERSION_EXTRA}
DRIVER_NAME=mlnx-en
DRIVER_URL=https://www.mellanox.com/downloads/ofed/${DRIVER_PACKAGE_NAME}-${DRIVER_VERSION}${DRIVER_VERSION_EXTRA}/${DRIVER_PACKAGE_NAME}_SRC-debian-${DRIVER_VERSION}${DRIVER_VERSION_EXTRA}.tgz
DRIVER_FILE=$(basename "${DRIVER_URL}")

# Build up Debian related variables required for packaging
DEBIAN_ARCH=$(dpkg --print-architecture)
DEBIAN_DIR=${CWD}/vyos-mellanox-${DRIVER_NAME}_${DRIVER_VERSION}${DRIVER_VERSION_EXTRA}_${DEBIAN_ARCH}
DEBIAN_CONTROL=${DEBIAN_DIR}/DEBIAN/control
DEBIAN_POSTINST=${DEBIAN_DIR}/DEBIAN/postinst

# Fetch Mellanox driver source
curl -fLo "${DRIVER_FILE}" "${DRIVER_URL}"

# Unpack archive
rm -rf "${DRIVER_DIR}"
tar xf "${DRIVER_FILE}"
cd "${DRIVER_DIR}/SOURCES"
tar xf "${DRIVER_NAME}_${DRIVER_VERSION}.orig.tar.gz"

cd "${DRIVER_NAME}-${DRIVER_VERSION}"
if [ -z "$KERNEL_DIR" ]; then
    echo "KERNEL_DIR not defined"
    exit 1
fi
echo "I: Compile Kernel module for Mellanox ${DRIVER_NAME} driver"
scripts/mlnx_en_patch.sh -k "${KERNEL_VERSION}${KERNEL_SUFFIX}" -s "${KERNEL_DIR}" -j "$(getconf _NPROCESSORS_ONLN)"
# the vyos docker build image (vyos/vyos-build:equuleus) is built on debian, that causes the makefile to run in dkms mode which we dont want
sed 's/debian|//' -i makefile
KSRC=${KERNEL_DIR} \
    INSTALL_MOD_PATH=${DEBIAN_DIR} \
    make -j "$(getconf _NPROCESSORS_ONLN)" kernel
KSRC=${KERNEL_DIR} \
    INSTALL_MOD_PATH=${DEBIAN_DIR} \
    make install
find "$DEBIAN_DIR" -ls

mkdir -p "$(dirname "${DEBIAN_CONTROL}")"
tee "${DEBIAN_CONTROL}" <<EOF
Package: vyos-mellanox-${DRIVER_NAME}
Version: ${DRIVER_VERSION}${DRIVER_VERSION_EXTRA}
Section: kernel
Priority: extra
Architecture: ${DEBIAN_ARCH}
Maintainer: VyOS Package Maintainers <maintainers@vyos.net>
Description: Vendor based driver for Mellanox ${DRIVER_PACKAGE_NAME}
Depends: linux-image-${KERNEL_VERSION}${KERNEL_SUFFIX}
EOF

# delete non required files which are also present in the kernel package
# und thus lead to duplicated files
find "${DEBIAN_DIR}" -name "modules.*" -print0 | xargs -0r rm -fv

tee "${DEBIAN_POSTINST}" <<EOF
#!/bin/sh
depmod -a -F "/boot/System.map-${KERNEL_VERSION}${KERNEL_SUFFIX}" "${KERNEL_VERSION}${KERNEL_SUFFIX}"
EOF
chmod 0775 "${DEBIAN_POSTINST}"

# build Debian package
echo "I: Building Debian package vyos-mellanox-${DRIVER_NAME}"
fakeroot dpkg-deb --build "${DEBIAN_DIR}"

# check the package looks right
if ! dpkg -c "$DEBIAN_DIR.deb" | grep -v ^d; then
    echo "Bad deb package: no files"
    exit 1
fi
if ! dpkg -c "$DEBIAN_DIR.deb" | grep "/lib/modules/${KERNEL_VERSION}${KERNEL_SUFFIX}/extra/mellanox-mlnx-en/drivers/net/ethernet/mellanox/mlx5/core/mlx5_core\.ko$"; then
    echo "Bad deb package: mlx5_core module not found"
    exit 1
fi

echo "I: Cleanup ${DRIVER_NAME} source"
cd "${CWD}"
rm -f "${DRIVER_FILE}"
rm -rf "${DRIVER_DIR}" "${DEBIAN_DIR}"
