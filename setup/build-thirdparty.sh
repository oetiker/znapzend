#!/bin/bash

. `dirname $0`/sdbs.inc

for module in \
  Sys::Syslog \
  Mojolicious@5.21 \
  Mojo::IOLoop::ForkCall@0.12 \
; do
perlmodule $module
done
