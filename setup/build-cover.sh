#!/bin/bash

. `dirname $0`/sdbs.inc

for module in \
    Devel::Cover::Report::Coveralls \
; do
perlmodule $module
done
