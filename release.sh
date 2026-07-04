#!/bin/sh
set -e
echo "release.sh has been retired."
echo
echo "To cut a release, run the 'Release' GitHub Actions workflow, e.g.:"
echo "  gh workflow run Release -f release_type=bugfix"
echo "(release_type is one of: bugfix, feature, major)"
echo
echo "It bumps VERSION, finalizes CHANGES, tags, builds and publishes the"
echo "release, and reopens CHANGES for development -- all in one run,"
echo "pushed directly to master."
exit 1
