#!/bin/sh
set -e
echo "release-finish.sh has been retired."
echo
echo "There is no separate finish step anymore -- the 'Release' GitHub"
echo "Actions workflow (.github/workflows/release-prepare.yml) does the"
echo "whole release, including tagging, building and publishing, in one run."
exit 1
