#!/bin/sh
autoreconf --force --install --verbose --make
test -d .git && git log --full-history --simplify-merges --dense --no-merges > CHANGES
# EOF
