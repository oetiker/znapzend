#!/bin/sh
set -e
V=$(cat VERSION)
P=znapzend
rm -f config.status
./bootstrap.sh
./configure
echo ${V} `date +"%Y-%m-%d %H:%M:%S %z"` `git config user.name` '<'`git config user.email`'>' > CHANGES.new
echo >> CHANGES.new
echo ' -' >> CHANGES.new
echo >> CHANGES.new
$EDITOR CHANGES.new
tail --line=+2 CHANGES.new | sed -e 's/^  //' > release-notes-$V.md
cat CHANGES >> CHANGES.new
mv CHANGES.new CHANGES
make
make dist
git checkout -b v${V}
git commit -a
git push --set-upstream origin v${V}
#gh release create v${V} --title "ZnapZend $V" --notes-file release-notes-$V.md ${P}-${V}.tar.gz'#Source Archive' 
