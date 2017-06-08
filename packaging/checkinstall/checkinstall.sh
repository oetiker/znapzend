#!/bin/bash

# Exit when encountering an undefined variable
set -u

_checkinstall() {
if [[ $EUID -ne 0 ]]; then
  checkinstall_cmd="sudo checkinstall"
else
  checkinstall_cmd="checkinstall"
fi

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
$checkinstall_cmd -y -D \
--maintainer="morph027" \
--install=no \
--pkgname=znapzend \
--pkgversion=$(git describe --abbrev=0 --tags | sed 's,^v,,') \
--pkglicense=GPL \
--pkgrelease=1 \
--pkgsource="https://github.com/oetiker/znapzend" \
--requires="${zfsutilsdep},mbuffer" \
--provides=znapzend \
--nodoc \
--backup=no \
--exclude='/home'
rm -f *-pak
}

if type checkinstall > /dev/null 2>&1 ; then
  _checkinstall
else
  echo "please install checkinstall"
  exit 1
fi
