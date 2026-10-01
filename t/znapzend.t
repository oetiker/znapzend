#!/usr/bin/env perl

use strict;
use warnings;

use FindBin;
$ENV{PATH} = $FindBin::RealBin . ':' . $ENV{PATH};
my $buildDir;

BEGIN {
    $buildDir = shift @ARGV // $FindBin::RealBin.'/../';
}

# PERL5LIB
use lib "$FindBin::Bin/../lib";
use lib "$buildDir/thirdparty/lib/perl5";
#place bin path to lib so it is stored in @INC
use lib "$FindBin::Bin/../bin";

unshift @INC, sub {
    my (undef, $filename) = @_;
    return () if $filename !~ /ZnapZend|znapzend/;
    if (my $found = (grep { -e $_ } map { "$_/$filename" } grep { !ref } @INC)[0] ) {
        local $/ = undef;
        open my $fh, '<', $found or die("Can't read module file $found\n");
        my $module_text = <$fh>;
        close $fh;

        # define everything in a sub, so Devel::Cover will DTRT
        # NB this introduces no extra linefeeds so D::C's line numbers
        # in reports match the file on disk
        $module_text =~ s/(.*?package\s+\S+)(.*)__END__/$1sub classWrapper {$2} classWrapper();/s;

        # uncomment testing code
        $module_text =~ s/### RM_COMM_4_TEST ###//sg;

        # unhide private methods to avoid "Variable will not stay shared"
        # warnings that appear due to change of applicable scoping rules
        # Note: not '\s*' in the start of string, to avoid matching and
        # removing blank lines before the private sub definitions.
        $module_text =~ s/^[ \t]*my\s+(\S+\s*=\s*sub.*)$/our $1/gm;

        if(defined($ENV{DEBUG_ZNAPZEND_SELFTEST_REWRITE})) {
            open(my $fhp, '>', $found . '.selftest-rewritten') or warn "Could not open " . $found . '.selftest-rewritten';
            if ($fhp) { print $fhp $module_text ; close $fhp; }
        }

        # filehandle on the scalar
        open $fh, '<', \$module_text;

        # and put it into %INC too so that it looks like we loaded the code
        # from the file directly
        $INC{$filename} = $found;
        return $fh;
    }
    else {
        return ();
    }
};

sub runCommand {
    @ARGV = @_;

    eval { main(); };

    if ($@) {
        # Presumably a die() handler caught something
        print STDERR "EXCEPTION: " . $@ . "\n";
        return 0;
    };

    # Return "true" if not failed :)
    1;
}

sub runCommand_canThrow {
    @ARGV = @_;

    main();
}

use Test::More;
use Test::Exception;
use File::Temp qw(tempfile);

use_ok 'ZnapZend';

#load program
@ARGV = qw(--help);
do 'znapzend' or die "ERROR: loading program znapzend $@\n";

# seems to allow tests to continue so why not?
is (runCommand('--help'), 1, 'znapzend help');

is (runCommand(), 1, 'znapzend');

throws_ok { runCommand_canThrow(qw(--runonce=nosets) ) } qr/No backup set defined or enabled/,
      'znapzend dies with no backup sets defined or enabled at startup';

$ENV{'ZNAPZENDTEST_ZFS_GET_ZEND_DELAY'} = '1';
is (runCommand(qw(--runonce=tank/source)), 1, 'znapzend --runonce=tank/source with zend-delay==1');
is (runCommand(qw(--nodelay --runonce=tank/source)), 1, 'znapzend --runonce=tank/source with zend-delay==1 and --nodelay (should ignore the plan setting)');
$ENV{'ZNAPZENDTEST_ZFS_GET_ZEND_DELAY'} = undef;

# Try an invalid string, should ignore and proceed without a delay
$ENV{'ZNAPZENDTEST_ZFS_GET_ZEND_DELAY'} = ' qwe ';
# TODO : Find a way to check stderr for qr/Option 'zend-delay' has an invalid value/
is (runCommand(qw(--runonce=tank/source)),
    1, 'znapzend --runonce=tank/source with zend-delay==" qwe " complains but survives');
$ENV{'ZNAPZENDTEST_ZFS_GET_ZEND_DELAY'} = undef;

is (runCommand(qw(--runonce)), 1, 'znapzend runonce without dataset specified succeeds (should find all backup plans)');
is (runCommand(qw(--runonce=)), 1, 'znapzend runonce with empty dataset == without dataset specified succeeds (should find all backup plans)');
is (runCommand(qw(--runonce=tank -r)), 1, 'znapzend runonce recursing from a dataset without plan (pool root) succeeds');

is (runCommand(qw(--inherited --runonce=tank/source/child)), 1, 'znapzend runonce of a dataset with only an inherited plan succeeds with --inherited flag');
is (runCommand(qw(--inherited --recursive --runonce=tank/source/child)), 1, 'znapzend runonce of a dataset with only an inherited plan succeeds with --inherited --recursive flag');
is (runCommand(qw(--inherited --recursive --runonce=tank)), 1, 'znapzend runonce of a dataset only whose descendants have a plan succeeds with --inherited --recursive flag');

# Coverage for various failure codepaths of inherited +/- recursive modes
is (runCommand(qw(--inherited --runonce=tank)), 0, 'znapzend runonce of a dataset without a plan fails also with --inherited flag');
is (runCommand(qw(--recursive --runonce=tank/source/child)), 0, 'znapzend runonce of a dataset with only an inherited plan fails with only --recursive flag and without --inherited');
is (runCommand(qw(--runonce=tank/source/child)), 0, 'znapzend runonce of a dataset with only an inherited plan fails without --inherit flag');
is (runCommand(qw(--runonce=tank/dest-disabled)), 1, 'cover znapzend runonce of a dataset with original backup plan and a disabled destination - does not fail');

# TODO: Add handling and testing for inherited-config datasets with a locally defined bits of the backup plan, e.g. disabled destinations?
#is (runCommand(qw(--inherited --runonce=tank/source/dest-disabled)), 0, 'cover znapzend runonce of a dataset with inherited backup plan and a disabled destination - such mixing is not supported at the moment');

# Valid and invalid variants of forced snapshot name
is (runCommand(qw(--runonce=tank/source --forcedSnapshotSuffix=manualsnap)), 1, 'znapzend --runonce=tank/source --forcedSnapshotSuffix=manualsnap succeeds');
#is (runCommand(qw(--runonce --forcedSnapshotSuffix=@manualsnap)), 1, 'znapzend --runonce --forcedSnapshotSuffix=@manualsnap succeeds (removes leading @)');
is (runCommand(qw(--runonce=tank/source --forcedSnapshotSuffix=@manualsnap)), 1, 'znapzend --runonce=tank/source --forcedSnapshotSuffix=@manualsnap succeeds (removes leading @)');

is (runCommand(qw(--runonce=tank/source --forcedSnapshotSuffix=manual@snap)), 0, 'znapzend --runonce=tank/source --forcedSnapshotSuffix=manual@snap fails (invalid chars in string)');
is (runCommand(qw(--runonce=tank/source), '--forcedSnapshotSuffix=manual snap'), 0, 'znapzend --runonce=tank/source --forcedSnapshotSuffix=manual" "snap fails (invalid chars in string)');
### SKIPPED : This one gets failed by arg processing routines in a way that test program is killed
#is (runCommand(qw(--runonce=tank/source --forcedSnapshotSuffix=)), 0, 'znapzend --runonce=tank/source --forcedSnapshotSuffix= fails (empty snapname)');
#throws_ok { runCommand_canThrow(qw(--runonce=tank/source --forcedSnapshotSuffix=) ) } qr/Option forcedSnapshotSuffix requires an argument/,
#      'znapzend --runonce=tank/source --forcedSnapshotSuffix= fails (empty snapname)';
is (runCommand(qw(--runonce=tank/source), '--forcedSnapshotSuffix= '), 0, 'znapzend --runonce=tank/source --forcedSnapshotSuffix=" " fails (snapname becomes empty after chomp)');
is (runCommand(qw(--forcedSnapshotSuffix=manualsnap)), 0, 'znapzend --forcedSnapshotSuffix=manualsnap fails (not in runonce mode)');

# The --since=x argument currently does not really have failure modes
# (a name might not be in the source dataset snapshot history, for whatever
# reason), so we just need to test its codepath for coverage mostly
is (runCommand(qw(--runonce=tank/source), '--since=20200101-stableSystem'), 1,
   'znapzend --runonce=tank/source --since=20200101-stableSystem succeeds');

# Series of tests over usual tank/source with different options
is (runCommand(qw(--runonce=tank/source), '--features=oracleMode,recvu,compressed'),
    1, 'znapzend --features=oracleMode,recvu,compressed --runonce=tank/source succeeds');
is (runCommand(qw(--runonce=tank/source), '--features=skipIntermediates'),
    1, 'znapzend --features=skipIntermediates --runonce=tank/source succeeds');
is (runCommand(qw(--runonce=tank/source -i -I), '--features=skipIntermediates'),
    1, 'znapzend --features=skipIntermediates --runonce=tank/source -i -I succeeds (should complain about both opposing flags used)');

# Coverage for various failure codepaths
$ENV{'ZNAPZENDTEST_ZFS_GET_DST0PRECMD_FAIL'} = '1';
is (runCommand(qw(--runonce=tank/source)), 1, 'znapzend sendRecvCleanup with a failed DST PRE command');
is (runCommand(qw(--runonce=tank/source --skipOnPreSnapCmdFail)), 1, 'znapzend sendRecvCleanup with a failed DST PRE command and --skipOnPreSnapCmdFail');
is (runCommand(qw(--runonce=tank/source --skipOnPreSendCmdFail)), 1, 'znapzend sendRecvCleanup with a failed DST PRE command and --skipOnPreSendCmdFail');
$ENV{'ZNAPZENDTEST_ZFS_GET_DST0PRECMD_FAIL'} = undef;

$ENV{'ZNAPZENDTEST_ZFS_GET_DST0PSTCMD_FAIL'} = '1';
is (runCommand(qw(--runonce=tank/source)), 1, 'znapzend sendRecvCleanup with a failed DST POST command');
is (runCommand(qw(--runonce=tank/source --skipOnPreSnapCmdFail)), 1, 'znapzend sendRecvCleanup with a failed DST POST command and --skipOnPreSnapCmdFail');
is (runCommand(qw(--runonce=tank/source --skipOnPreSendCmdFail)), 1, 'znapzend sendRecvCleanup with a failed DST POST command and --skipOnPreSendCmdFail');
$ENV{'ZNAPZENDTEST_ZFS_GET_DST0PSTCMD_FAIL'} = undef;

$ENV{'ZNAPZENDTEST_ZFS_FAIL_send'} = '1';
is (runCommand(qw(--runonce=tank/source)), 1, 'znapzend sendRecvCleanup with a failed ZFS SEND command');
$ENV{'ZNAPZENDTEST_ZFS_FAIL_send'} = undef;

$ENV{'ZNAPZENDTEST_ZFS_FAIL_recv'} = '1';
is (runCommand(qw(--runonce=tank/source)), 1, 'znapzend sendRecvCleanup with a failed ZFS RECV command');
$ENV{'ZNAPZENDTEST_ZFS_FAIL_recv'} = undef;

$ENV{'ZNAPZENDTEST_ZFS_FAIL_destroy'} = '1';
is (runCommand(qw(--runonce=tank/source)), 1, 'znapzend sendRecvCleanup with a failed ZFS DESTROY command');
$ENV{'ZNAPZENDTEST_ZFS_FAIL_destroy'} = undef;

$ENV{'ZNAPZENDTEST_ZFS_FAIL_snapshot'} = '1';
is (runCommand(qw(--runonce=tank/source)), 1, 'znapzend sendRecvCleanup with a failed ZFS snapshot command');
$ENV{'ZNAPZENDTEST_ZFS_FAIL_snapshot'} = undef;

$ENV{'ZNAPZENDTEST_ZFS_SUCCEED_snapshot'} = '1';
is (runCommand(qw(--runonce=tank/source)), 1, 'znapzend sendRecvCleanup with a successful ZFS snapshot command');
$ENV{'ZNAPZENDTEST_ZFS_SUCCEED_snapshot'} = undef;

is (runCommand(qw(--runonce=tank/source --autoCreation)), 1, 'znapzend --autoCreation --runonce=tank/source');
$ENV{'ZNAPZENDTEST_ZFS_FAIL_create'} = '1';
is (runCommand(qw(--runonce=tank/source --autoCreation)), 0, 'znapzend --autoCreation --runonce=tank/source with a failed ZFS create command - fails');
$ENV{'ZNAPZENDTEST_ZFS_FAIL_create'} = undef;

is (runCommand(qw(--runonce=tank/source), '--features=zfsGetType'),
    1, 'znapzend --features=zfsGetType --runonce=tank/source succeeds with new ZFS');
is (runCommand(qw(--inherited --runonce=tank/source/child --features=zfsGetType)),
    1, 'znapzend --inherited --features=zfsGetType --runonce=tank/source/child succeeds with new ZFS');
$ENV{'ZNAPZENDTEST_ZFS_GET_TYPE_UNHANDLED'} = '1';
is (runCommand(qw(--runonce=tank/source), '--features=zfsGetType'),
    0, 'znapzend --features=zfsGetType --runonce=tank/source fails with old ZFS');
$ENV{'ZNAPZENDTEST_ZFS_GET_TYPE_UNHANDLED'} = undef;
undef $ENV{'ZNAPZENDTEST_ZFS_GET_TYPE_UNHANDLED'};

# Cover another codepath for ZFS that lists snapshots by default
$ENV{'ZNAPZENDTEST_ZPOOL_DEFAULT_listsnapshots'} = 'on';
is (runCommand(qw(--runonce=tank/source), '--features=zfsGetType'),
    1, 'znapzend --features=zfsGetType --runonce=tank/source succeeds with new ZFS when it lists snapshots');
is (runCommand(qw(--runonce=tank/source)),
    1, 'znapzend --runonce=tank/source succeeds with new ZFS when it lists snapshots');
is (runCommand(qw(--inherited --recursive --runonce=tank/source/child --features=zfsGetType)),
    1, 'znapzend --inherited --recursive --features=zfsGetType --runonce=tank/source/child succeeds with new ZFS when it lists snapshots');
$ENV{'ZNAPZENDTEST_ZFS_GET_TYPE_UNHANDLED'} = '1';
is (runCommand(qw(--runonce=tank/source), '--features=zfsGetType'),
    0, 'znapzend --features=zfsGetType --runonce=tank/source fails with old ZFS when it lists snapshots');
$ENV{'ZNAPZENDTEST_ZFS_GET_TYPE_UNHANDLED'} = undef;
$ENV{'ZNAPZENDTEST_ZPOOL_DEFAULT_listsnapshots'} = undef;

# Test codepath for cleaning of snapshots even if destination is offline
is (runCommand(qw(--cleanOffline --debug)),
    1, 'znapzend --cleanOffline succeeds');

# Opt-in per-destination concurrency: advertise destination_concurrency on the
# mock config and run once so the real parallel worker pool executes (this file
# strips ### RM_COMM_4_TEST ###, so sendRecvCleanup runs directly and reaches
# the pool branch with the 3 fixture destinations).
#
# The mock 'zfs recv' can hold each receive open and log timestamped START/END
# lines (ZNAPZENDTEST_ZFS_RECV_SLEEP / _RECV_TRACE). From that trace we can
# measure how many receives were in flight at once, which is the only
# observable that distinguishes a real parallel pool from one that silently
# fell back to serial execution.
{
    # Parse a recv trace into [ [start, end, dest], ... ] intervals.
    my $readTrace = sub {
        my ($file) = @_;
        my (%open, @intervals);
        open(my $fh, '<', $file) or return @intervals;
        while (my $line = <$fh>) {
            my ($what, $pid, $time, $dest) = split ' ', $line;
            next unless defined $dest;
            if ($what eq 'START') { $open{$pid} = [$time, undef, $dest]; }
            elsif ($what eq 'END' && $open{$pid}) {
                $open{$pid}[1] = $time;
                push @intervals, delete $open{$pid};
            }
        }
        close $fh;
        return @intervals;
    };

    # Largest number of intervals open at the same instant.
    my $maxOverlap = sub {
        my @events;
        for my $iv (@_) {
            push @events, [$iv->[0], 1], [$iv->[1], -1];
        }
        my ($cur, $max) = (0, 0);
        # An interval ending at the same instant another starts does not overlap.
        for my $ev (sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] } @events) {
            $cur += $ev->[1];
            $max = $cur if $cur > $max;
        }
        return $max;
    };

    # Run once with receive tracing; returns (ok, intervals, log text).
    my $tracedRun = sub {
        my @args = @_;
        my (undef, $traceFile) = tempfile('znapzend-recv-trace-XXXXXX', TMPDIR => 1, OPEN => 0);
        my (undef, $logFile)   = tempfile('znapzend-recv-log-XXXXXX',   TMPDIR => 1, OPEN => 0);
        local $ENV{'ZNAPZENDTEST_ZFS_RECV_SLEEP'} = '1';
        local $ENV{'ZNAPZENDTEST_ZFS_RECV_TRACE'} = $traceFile;
        my $ok = runCommand(@args, "--logto=$logFile");
        my @intervals = $readTrace->($traceFile);
        my $log = '';
        if (open(my $fh, '<', $logFile)) { local $/; $log = <$fh> // ''; close $fh; }
        unlink $traceFile, $logFile;
        return ($ok, \@intervals, $log);
    };

    # Baseline: no opt-in => destinations are received strictly one at a time.
    # (Of the mock's three destinations, dst_0 and dst_a are the valid ones.)
    my ($ok, $iv) = $tracedRun->(qw(--cleanOffline --runonce=tank/source));
    is ($ok, 1, 'serial default: znapzend --runonce completes');
    is (scalar(@$iv), 2, 'serial default: traced a receive for each valid destination');
    is ($maxOverlap->(@$iv), 1, 'serial default: never more than one receive in flight');

    # Opt-in: the pool really overlaps receives.
    local $ENV{'ZNAPZENDTEST_ZFS_GET_DST_CONCURRENCY'} = '3';
    ($ok, $iv) = $tracedRun->(qw(--cleanOffline --runonce=tank/source));
    is ($ok, 1, 'destination_concurrency=3: znapzend --runonce completes');
    is ($maxOverlap->(@$iv), 2,
        'destination_concurrency=3: receives to different destinations overlap (parallel pool, not a serial fallback)');

    # The numeric limit is honoured. Add a third valid destination on a
    # DIFFERENT remote host (so nothing forces it to wait on dst_a): all three
    # can run together at limit 3, but only two at limit 2.
    local $ENV{'ZNAPZENDTEST_ZFS_GET_DST_EXTRA_REMOTE'} = 'remote2';
    ($ok, $iv) = $tracedRun->(qw(--cleanOffline --runonce=tank/source));
    is ($ok, 1, 'three destinations, limit 3: znapzend --runonce completes');
    is ($maxOverlap->(@$iv), 3, 'three destinations, limit 3: all three receive together');

    $ENV{'ZNAPZENDTEST_ZFS_GET_DST_CONCURRENCY'} = '2';
    ($ok, $iv) = $tracedRun->(qw(--cleanOffline --runonce=tank/source));
    is ($ok, 1, 'three destinations, limit 2: znapzend --runonce completes');
    is ($maxOverlap->(@$iv), 2, 'three destinations, limit 2: no more than 2 receives in flight');
    delete $ENV{'ZNAPZENDTEST_ZFS_GET_DST_EXTRA_REMOTE'};

    # Failure aggregation: make dst_0's pre-send-command fail with
    # --skipOnPreSendCmdFail, which records dst_0 as a failed send. That must
    # reach the failure summary in parallel mode exactly as it does serially --
    # losing it would let source cleanup proceed as if every destination had
    # synced.
    local $ENV{'ZNAPZENDTEST_ZFS_GET_DST0PRECMD_FAIL'} = '1';
    my %failCount;
    for my $mode (qw(serial parallel)) {
        $ENV{'ZNAPZENDTEST_ZFS_GET_DST_CONCURRENCY'} = $mode eq 'parallel' ? '3' : undef;
        my $log;
        ($ok, undef, $log) = $tracedRun->(qw(--cleanOffline --skipOnPreSendCmdFail --runonce=tank/source));
        is ($ok, 1, "$mode: run with one failing destination still completes under --cleanOffline");
        like ($log, qr/ERROR: \d+ send task\(s\) below failed for tank\/source/,
            "$mode: a failed send is reported in the failure summary");
        like ($log, qr/\+-->\s+skipping backup\/destination due to pre-send-command failure/,
            "$mode: the summary names the failing destination");
        ($failCount{$mode}) = $log =~ /ERROR: (\d+) send task\(s\) below failed/;
    }
    ok (defined($failCount{serial}) && defined($failCount{parallel}) && $failCount{parallel} == $failCount{serial},
        'the parallel pool reports the same number of failed sends as serial execution');
    delete $ENV{'ZNAPZENDTEST_ZFS_GET_DST0PRECMD_FAIL'};

    # Destinations on the same remote host share a remote mbuffer port; their
    # receivers cannot run at once, so the pool must serialize them while still
    # overlapping unrelated destinations.
    $ENV{'ZNAPZENDTEST_ZFS_GET_DST_CONCURRENCY'} = '3';
    $ENV{'ZNAPZENDTEST_ZFS_GET_DST_EXTRA_REMOTE'} = 'remote';
    ($ok, $iv) = $tracedRun->(qw(--cleanOffline --runonce=tank/source));
    is ($ok, 1, 'same-host destinations: znapzend --runonce completes');
    my @remote = grep { $_->[2] =~ m{^remote/} } @$iv;
    is (scalar(@remote), 2, 'same-host destinations: traced a receive for each destination on the shared remote host');
    is ($maxOverlap->(@remote), 1,
        'same-host destinations: receives sharing a remote mbuffer port never overlap');
    is ($maxOverlap->(@$iv), 2,
        'same-host destinations: an unrelated (local) destination still runs in parallel with them');
}
$ENV{'ZNAPZENDTEST_ZFS_GET_DST_CONCURRENCY'} = undef;

# Read path must TOLERATE an out-of-band-invalid concurrency value (e.g. set by
# a manual `zfs set`): the config check warns and the runtime falls back to
# serial, rather than dying uncaught and taking down every backup set. Before
# the read-path fix this run died at config read. (review finding #1)
$ENV{'ZNAPZENDTEST_ZFS_GET_DST_CONCURRENCY'} = 'bogus';
is (runCommand(qw(--cleanOffline --runonce=tank/source)),
    1, 'znapzend --runonce tolerates an invalid destination_concurrency (serial fallback, no crash)');
$ENV{'ZNAPZENDTEST_ZFS_GET_DST_CONCURRENCY'} = undef;

# Note: test for daemonized mode are offloaded to another file

done_testing;

1;
