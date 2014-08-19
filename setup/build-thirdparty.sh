#!/bin/bash

. `dirname $0`/sdbs.inc

#  Sys::Syslog \

for module in \
  Mojolicious@5.30 \
  Mojo::IOLoop::ForkCall@0.14 \
; do
perlmodule $module
done
