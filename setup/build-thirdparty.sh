#!/bin/bash

. `dirname $0`/sdbs.inc

for module in \
  Mojolicious \
; do
perlmodule $module
done
