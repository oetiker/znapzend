#!/bin/bash

make clean
./configure --prefix=/usr
make
ln -s packaging/checkinstall/*-pak .
sudo checkinstall --install=no --pkgname=znapzend --pkgversion=$(git describe --abbrev=0 --tags | sed 's,^v,,') --pkglicense=GPL --pkgrelease=1 --pkgsource="https://github.com/oetiker/znapzend" --requires="zfsutils,mbuffer" --provides=znapzend --nodoc --backup=no
rm -f *-pak
