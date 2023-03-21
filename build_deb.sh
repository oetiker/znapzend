#!/bin/sh
set -ex

DISTRIBUTION_NAME=$1

# Overriding $HOME to prevent permissions issues when running on github actions
mkdir -p /tmp/home
chmod 0777 /tmp/home
export HOME=/tmp/home

# workaround for debhelper bug: https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=897569
mkdir -p deb_build_home
ls | grep -v deb_build_home | xargs mv -n -t deb_build_home # move everything except deb_build_home
cd deb_build_home

dh_clean
dpkg-buildpackage -us -uc -nc

# set filename
release_code_name=$(cat /etc/os-release | grep VERSION_CODENAME | cut -d'=' -f 2)
package_name=$(basename ../*.deb | sed 's/.deb$//')_${DISTRIBUTION_NAME}_${release_code_name}.deb
mv ../*.deb ../$package_name

# set action output
echo "package_name=$package_name" >> $GITHUB_OUTPUT
