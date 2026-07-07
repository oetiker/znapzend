#!/usr/bin/env perl

# Test ZnapZend::Config::checkBackupSet() with a backup set that configures
# no mbuffer at all (neither the legacy 'mbuffer' property nor a per-destination
# 'dst_X_mbuffer'). Such a set leaves dst_X_mbuffer undefined; checkBackupSet
# must treat that as "mbuffer off" and not fall into mbuffer validation (which
# would emit uninitialized-value warnings and die with a bogus
# "mbuffer size '' invalid").

use strict;
use warnings;

use FindBin;
$ENV{PATH} = $FindBin::RealBin . ':' . $ENV{PATH};
my $buildDir;

BEGIN {
    $buildDir = shift @ARGV // $FindBin::RealBin . '/../';
}

use lib "$FindBin::RealBin/../lib";
use lib "$buildDir/thirdparty/lib/perl5";

use Test::More;
use Test::Exception;
use Mojo::Log;

use_ok 'ZnapZend::Config';

my $zLog = Mojo::Log->new(level => 'fatal');
my $cfg = ZnapZend::Config->new(zLog => $zLog, debug => 0);
isa_ok($cfg, 'ZnapZend::Config');

my $bs = $cfg->getBackupSet(0, 0, 'tank/source')->[0];
ok($bs && $bs->{src} eq 'tank/source', 'got backup set for tank/source');

# Simulate a configuration that does not use mbuffer anywhere:
# drop the legacy 'mbuffer'/'mbuffer_size' and every per-destination
# mbuffer property, leaving dst_X_mbuffer to default to undef.
delete $bs->{$_} for grep { /mbuffer/ } keys %$bs;

lives_ok { $cfg->checkBackupSet($bs) }
    'checkBackupSet tolerates a backup set without any mbuffer configuration';

done_testing;

1;
