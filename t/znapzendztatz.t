#!/usr/bin/env perl

use FindBin;
$ENV{PATH} .= ":$FindBin::Bin/../bin:$FindBin::Bin";

use Test::More tests => 2;

isnt (system(qw(znapzendztatz --help)), 0, 'znapzendztatz help');
 
is (system(qw(znapzendztatz)), 0, 'znapzendztatz');

1;

