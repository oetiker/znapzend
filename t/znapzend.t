#!/usr/bin/env perl

use strict;
use warnings;

use FindBin;
$ENV{PATH} .= ":$FindBin::Bin";

my $binDir;
BEGIN {
    $binDir = shift;
    $binDir //= "$FindBin::Bin/../bin";
}

use lib "$binDir/../lib";
use lib "$binDir/../thirdparty/lib/perl5";

use ZnapZend;

my @cmdPrefix = ('perl', "-I$binDir/../thirdparty/lib/perl5",
    "-MDevel::Cover=+ignore,thirdparty");

use Test::More tests => 1;

isnt (system(@cmdPrefix, "$binDir/znapzend", '--help'), 0, 'znapzend help');
 
1;

