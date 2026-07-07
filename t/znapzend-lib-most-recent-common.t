#!/usr/bin/env perl

# Test ZnapZend::ZFS::mostRecentCommonSnapshot().
#
# The method must return the most recent snapshot that source and a
# *live* (reachable) destination have in common. Only when no live
# common snapshot can be determined should it fall back to the saved
# "last known synced" snapshot recorded in source-side properties.
#
# The mock `zfs` (t/zfs) lists the OLDEST source snapshot as also
# present on the destination, while it claims (via dst_X_synced
# properties) that the NEWEST source snapshot was synced. A correct
# implementation therefore returns the oldest (the genuinely common
# one); a regression that ignores the live information returns the
# newest (the property-based guess), which does not exist on the
# destination at all.

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
use Mojo::Log;

use_ok 'ZnapZend::ZFS';

# Keep logger quiet; we only care about return values here.
my $zLog = Mojo::Log->new(level => 'fatal');
my $zZFS = ZnapZend::ZFS->new(zLog => $zLog, debug => 0);
is (ref $zZFS, 'ZnapZend::ZFS', 'instantiation of ZFS');

# Make the mock list a small, deterministic set of snapshots:
# destination gets exactly one (the oldest), source gets three.
$ENV{'ZNAPZENDTEST_ZFS_list_max_snapshots'} = '1';

my $dstSnaps = $zZFS->listSnapshots('backup/destination');
is (scalar @$dstSnaps, 1,
    'precondition: destination has exactly one (the oldest) snapshot');

my ($dstSnapName) = $dstSnaps->[0] =~ /\@(.+)$/;

my $common = $zZFS->mostRecentCommonSnapshot(
    'tank/source', 'backup/destination', 'dst_0', qr/.*/);

is ($common, "tank/source\@$dstSnapName",
    'mostRecentCommonSnapshot returns the live common snapshot, '
    . 'not a property-fallback guess');

# --- Safety property: protection from source cleanup ---------------------
#
# The value returned here is the snapshot that sendRecvCleanup() protects
# from retention cleanup of the source, via the idiom:
#
#     @{$toDestroy} = grep { $recentCommon ne $_ } @{$toDestroy};
#
# It MUST therefore be the snapshot that genuinely exists on both source and
# destination (a valid incremental-send base). The stale dst_X_synced
# property in the mock points at the NEWEST source snapshot, which is NOT on
# the destination; protecting that one instead would leave the real common
# base eligible for deletion and break incremental replication.

my $srcSnaps  = $zZFS->listSnapshots('tank/source');
my $newestSrc = $srcSnaps->[-1];             # what the stale property would pick
my $realBase  = "tank/source\@$dstSnapName"; # the genuine common base (on the dst)

isnt ($common, $newestSrc,
    'protected snapshot is NOT the stale-property (newest source-only) snapshot');
is ($common, $realBase,
    'protected snapshot is the genuine common base present on the destination');

# Emulate retention wanting to destroy every source snapshot, then apply the
# production protection idiom with the returned common snapshot.
my @toDestroy = grep { $common ne $_ } @$srcSnaps;

ok ( !(grep { $_ eq $realBase } @toDestroy),
    'the real common base is protected from source cleanup (not in destroy list)');
ok ( (grep { $_ eq $newestSrc } @toDestroy),
    'source-only snapshots remain eligible for retention cleanup');

$ENV{'ZNAPZENDTEST_ZFS_list_max_snapshots'} = undef;

done_testing;

1;
