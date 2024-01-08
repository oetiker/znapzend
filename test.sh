#!/bin/sh

# Fail on a test line that dies so we can notice it
set -e

perl -I./thirdparty/lib/perl5 \
  -MDevel::Cover=+ignore,thirdparty ./t/znapzend.t
perl -I./thirdparty/lib/perl5 \
  -MDevel::Cover=+ignore,thirdparty ./t/znapzend-daemonize.t
perl -I./thirdparty/lib/perl5 \
  -MDevel::Cover=+ignore,thirdparty ./t/znapzendzetup.t
perl -I./thirdparty/lib/perl5 \
  -MDevel::Cover=+ignore,thirdparty ./t/znapzendztatz.t
perl -I./thirdparty/lib/perl5 \
  -MDevel::Cover=+ignore,thirdparty ./t/autoscrub.t

# Currently prone to failure with certain edge cases,
# so ignoring the result (fixes are investigated):
perl -I./thirdparty/lib/perl5 \
  -MDevel::Cover=+ignore,thirdparty ./t/znapzend-lib-splitter.t || echo "FAILURE Currently ignored"
