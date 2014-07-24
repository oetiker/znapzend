#!/bin/bash

. `dirname $0`/sdbs.inc

for module in \
  Mojolicious \
  IO::Pipely \
; do
perlmodule $module
done
