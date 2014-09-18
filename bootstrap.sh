#!/bin/sh
autoreconf --force --install --verbose --make
git log --full-history --simplify-merges --dense --no-merges > CHANGES
# EOF
