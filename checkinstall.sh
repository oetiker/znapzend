#!/bin/sh

make clean
./configure --prefix=/usr
make
sudo checkinstall --install=no --pkgname=znapzend --pkgversion=$(git describe --abbrev=0 --tags | sed 's,^v,,') --pkglicense=GPL --pkgrelease=1 --pkgsource="https://github.com/oetiker/znapzend" --requires="zfsutils,mbuffer" --provides=znapzend --nodoc
