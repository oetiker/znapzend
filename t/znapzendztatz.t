#!/usr/bin/env perl

use FindBin;
$ENV{PATH} .= ":$FindBin::Bin";

my $binDir = shift;
$binDir //= "$FindBin::Bin/../bin";

my @cmdPrefix = ('perl', "-I$binDir/../thirdparty/lib/perl5",
    "-MDevel::Cover=+ignore,Base.pm,Util.pm,Carp.pm");

use Test::More tests => 2;

isnt (system(@cmdPrefix, "$binDir/znapzendztatz", '--help'), 0, 'znapzendztatz help');
 
is (system(@cmdPrefix, "$binDir/znapzendztatz"), 0, 'znapzendztatz');

1;

