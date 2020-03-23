#!/bin/sh
autoreconf --force --install --verbose --make
if test -d .git; then
  git log --full-history --simplify-merges --dense --no-merges > CHANGES
fi
# EOF
