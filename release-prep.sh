#!/bin/sh
set -e
V=$(cat VERSION)
P=znapzend
rm -f config.status
./bootstrap.sh
./configure
VERSION=$(cat VERSION)
debchange -m -v $V
make
make dist
git checkout -b v${V} || true
git commit -a
git push --set-upstream origin v${V}
#gh release create v${V} --title "ZnapZend $V" --notes-file release-notes-$V.md ${P}-${V}.tar.gz'#Source Archive' 
