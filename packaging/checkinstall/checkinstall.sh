#!/bin/bash

# Exit when encountering an undefined variable
set -u

# Determine the Ubuntu version we are running on. Versions before
# 16.04 had a package called zfsutils, from 16.04 onwards the package
# is called zfsutils-linux
DistroMajorVersion=$(lsb_release -r |cut -f2 | cut -d. -f1)
DistroMinorVersion=$(lsb_release -r |cut -f2 | cut -d. -f2)
if [ ${DistroMajorVersion} -ge 16 ] && [ ${DistroMinorVersion} -ge 4 ]; then
    zfsutilsdep="zfsutils-linux"
else
    zfsutilsdep="zfsutils"
fi

# Compile znapzend
make clean
./configure --prefix=/usr
make

# Create the package
ln -s packaging/checkinstall/*-pak .
sudo checkinstall --default \
                  --install=no \
                  --pkgname=znapzend \
                  --pkgversion=$(git describe --abbrev=0 --tags | sed 's,^v,,') \
                  --pkglicense=GPL \
                  --pkgrelease=1 \
                  --pkgsource="https://github.com/oetiker/znapzend" \
                  --requires="${zfsutilsdep}\|zfs,mbuffer" \
                  --provides=znapzend \
                  --nodoc \
                  --backup=no
rm -f *-pak
