#!/bin/bash

. `dirname $0`/sdbs.inc

for module in \
    Devel::Cover::Report::Coveralls \
    IO::Socket::SSL \
; do
perlmodule $module
done
