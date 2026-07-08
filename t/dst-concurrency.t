#!/usr/bin/env perl

# Tests for opt-in per-destination send concurrency
# (znapzendzetup --dst-concurrency, backed by the destination_concurrency /
# destination_concurrency_enabled properties).
#
# The effective worker count is computed by ZnapZend::_resolveDstConcurrency,
# kept as a named method precisely so the resolution logic can be tested
# directly and deterministically here -- rather than relying on fragile timing
# of real parallel forks. The end-to-end parallel worker pool itself is
# exercised by t/znapzend.t (which advertises destination_concurrency on the
# mock config and runs the real send path), and the CLI parsing/validation is
# covered by t/znapzendzetup.t.

use strict;
use warnings;

use FindBin;
$ENV{PATH} = $FindBin::RealBin . ':' . $ENV{PATH};
my $buildDir;

BEGIN {
    $buildDir = shift @ARGV // $FindBin::RealBin.'/../';
}

use lib "$FindBin::Bin/../lib";
use lib "$buildDir/thirdparty/lib/perl5";
use lib "$FindBin::Bin/../bin";

use Test::More;

use_ok 'ZnapZend';

my $zz = ZnapZend->new;

# Helper: a backup set hash carrying only the concurrency-relevant properties.
sub bset {
    my %props = @_;
    return { src => 'tank/source', %props };
}

### Default / backward-compatibility ########################################

# No marker at all -> serial. This is the critical backward-compatibility case:
# every configuration created before this feature has no marker and must keep
# processing destinations one at a time.
is($zz->_resolveDstConcurrency(bset(), 3), 1,
    'unset marker => serial (1), 3 destinations (backward compatible)');
is($zz->_resolveDstConcurrency(bset(), 0), 1,
    'unset marker => serial (1), no destinations');

# A stray numeric limit without the enabling marker is ignored (serial).
is($zz->_resolveDstConcurrency(bset(destination_concurrency => 3), 3), 1,
    'numeric limit without enabled marker is ignored => serial');

# Explicitly disabled -> serial.
is($zz->_resolveDstConcurrency(bset(destination_concurrency_enabled => 'off'), 3), 1,
    'enabled=off => serial (1)');
is($zz->_resolveDstConcurrency(
        bset(destination_concurrency_enabled => 'off', destination_concurrency => 2), 3), 1,
    'enabled=off ignores any numeric limit => serial (1)');

### Opt-in parallelism ######################################################

# Enabled with no numeric limit -> all destinations.
is($zz->_resolveDstConcurrency(bset(destination_concurrency_enabled => 'on'), 3), 3,
    'enabled=on, no limit => all destinations');

# Enabled with a numeric limit below the destination count -> that limit.
is($zz->_resolveDstConcurrency(
        bset(destination_concurrency_enabled => 'on', destination_concurrency => 2), 3), 2,
    'enabled=on, limit=2, 3 destinations => 2');

# The limit is clamped to the destination count.
is($zz->_resolveDstConcurrency(
        bset(destination_concurrency_enabled => 'on', destination_concurrency => 10), 3), 3,
    'enabled=on, limit=10, 3 destinations => clamped to 3');

# A limit of 1 is just serial.
is($zz->_resolveDstConcurrency(
        bset(destination_concurrency_enabled => 'on', destination_concurrency => 1), 3), 1,
    'enabled=on, limit=1 => serial (1)');

### Hardening against invalid stored values #################################

# enabled=on with a present-but-invalid limit falls back to serial rather than
# silently maxing out fan-out. Only reachable via a manual `zfs set`, since
# znapzendzetup validates the value.
is($zz->_resolveDstConcurrency(
        bset(destination_concurrency_enabled => 'on', destination_concurrency => 0), 3), 1,
    'enabled=on, limit=0 (invalid) => serial (1), not "all"');
is($zz->_resolveDstConcurrency(
        bset(destination_concurrency_enabled => 'on', destination_concurrency => 'abc'), 3), 1,
    'enabled=on, non-numeric limit => serial (1), not "all"');

# enabled=on with an empty-string limit is treated as "no limit" => all.
is($zz->_resolveDstConcurrency(
        bset(destination_concurrency_enabled => 'on', destination_concurrency => ''), 3), 3,
    'enabled=on, empty-string limit => all destinations');

done_testing;

1;
