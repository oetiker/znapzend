#!/usr/bin/env perl

use FindBin;
$ENV{PATH} .= ":$FindBin::Bin/../bin:$FindBin::Bin";

use Test::More tests => 5;

isnt (system(qw(znapzendzetup --help)), 0, 'znapzendzetup help');
 
is (system(qw(znapzendzetup list)), 0, 'znapzendzetup list');

#is (system(qw(znapzendzetup create SRC 1h=>10min tank/source),
#    qw( DST 1h=>10min backup/destination)), 0, 'znapzendzetup create');

is (system(qw(znapzendzetup enable tank/source)), 0, 'znapzendzetup enable');

is (system(qw(znapzendzetup disable tank/source)), 0, 'znapzendzetup disable');

is (system(qw(znapzendzetup delete tank/source)), 0, 'znapzendzetup delete');

1;

