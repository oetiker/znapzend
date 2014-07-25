#!/bin/bash

. `dirname $0`/sdbs.inc

for module in \
  Mojolicious \
  Mojo::IOLoop::ForkCall \
; do
perlmodule $module
done
