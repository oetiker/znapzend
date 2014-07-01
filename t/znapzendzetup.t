#!/usr/bin/env perl

use strict;
use warnings;

use FindBin;
$ENV{PATH} .= ":$FindBin::Bin";

my $binDir = shift @ARGV;
$binDir //= "$FindBin::Bin/../bin";

my @cmdPrefix = ('perl', "-I$binDir/../thirdparty/lib/perl5", '-MDevel::Cover');

use Test::More tests => 5;

isnt (system(@cmdPrefix, "$binDir/znapzendzetup", '--help'), 0, 'znapzendzetup help');
 
is (system(@cmdPrefix, "$binDir/znapzendzetup", 'list'), 0, 'znapzendzetup list');

#is (system(qw(znapzendzetup create SRC 1h=>10min tank/source),
#    qw( DST 1h=>10min backup/destination)), 0, 'znapzendzetup create');

is (system(@cmdPrefix, "$binDir/znapzendzetup", qw(enable tank/source)), 0, 'znapzendzetup enable');

is (system(@cmdPrefix, "$binDir/znapzendzetup", qw(disable tank/source)), 0, 'znapzendzetup disable');

is (system(@cmdPrefix, "$binDir/znapzendzetup", qw(delete tank/source)), 0, 'znapzendzetup delete');

1;

