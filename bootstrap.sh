#!/bin/sh
autoreconf --force --install --verbose --make || exit
if (which git 2>/dev/null >/dev/null) && test -d .git; then
  git log --full-history --simplify-merges --dense --no-merges > CHANGES
fi
# EOF
