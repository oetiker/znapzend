#!/bin/bash
set -ex

DISTRIBUTION_NAME=$1
DISTRIBUTION_VERSION=$2

 Overriding $HOME to prevent permissions issues when running on github actions
mkdir -p /tmp/home
chmod 0777 /tmp/home
export HOME=/tmp/home

dh_clean
dpkg-buildpackage -us -uc -nc

# set filename
# znapzend_$VERSION~$DISTRIBUTIONNAME$DISTRIBUTION_VERSION_amd64.deb
release_number=${DISTRIBUTION_VERSION:0:2}
package_name=$(basename ../znapzend_*.deb | sed 's/_amd64.deb$//')~${DISTRIBUTION_NAME}${release_number}_amd64.deb
mv ../znapzend_*.deb "$package_name"

# set action output
echo "package_name=$package_name" >> $GITHUB_OUTPUT
