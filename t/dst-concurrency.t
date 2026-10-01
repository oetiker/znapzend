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

# Unhide the module's private `my $x = sub` closures (as t/znapzend.t does), so
# the daemon's shutdown handler ($killThemAll) can be exercised directly.
unshift @INC, sub {
    my (undef, $filename) = @_;
    return () if $filename !~ /ZnapZend|znapzend/;
    if (my $found = (grep { -e $_ } map { "$_/$filename" } grep { !ref } @INC)[0] ) {
        local $/ = undef;
        open my $fh, '<', $found or die("Can't read module file $found\n");
        my $module_text = <$fh>;
        close $fh;
        $module_text =~ s/(.*?package\s+\S+)(.*)__END__/$1sub classWrapper {$2} classWrapper();/s;
        $module_text =~ s/### RM_COMM_4_TEST ###//sg;
        $module_text =~ s/^[ \t]*my\s+(\S+\s*=\s*sub.*)$/our $1/gm;
        open $fh, '<', \$module_text;
        $INC{$filename} = $found;
        return $fh;
    }
    else {
        return ();
    }
};

no warnings 'once'; # $ZnapZend::killThemAll is only reached by name below
use POSIX qw(:sys_wait_h SIGTERM _exit);
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

### Remote mbuffer endpoint (parallel workers must not share one) ###########

# Two destinations that receive through the same remote host:port cannot run at
# the same time -- both would start `mbuffer -I <port>` there -- so the worker
# pool serializes them using this key.
sub eset {
    my %props = @_;
    return { src => 'tank/source', src_mbuffer => '/usr/bin/mbuffer', %props };
}
is($zz->_dstMbufferEndpoint(
        eset(dst_a => 'root@backup1:pool/ds', dst_a_mbuffer => '/usr/bin/mbuffer:9090'), 'dst_a'),
    'backup1:9090', 'remote destination with a port => "host:port" (user@ stripped)');
is($zz->_dstMbufferEndpoint(
        eset(dst_a => 'BackupHost:pool/ds', dst_a_mbuffer => '/usr/bin/mbuffer:9090'), 'dst_a'),
    'backuphost:9090', 'host name is case-folded');
is($zz->_dstMbufferEndpoint(
        eset(dst_a => 'backup1:pool/ds', dst_a_mbuffer => '/usr/bin/mbuffer:9090'), 'dst_a'),
    $zz->_dstMbufferEndpoint(
        eset(dst_b => 'root@backup1:pool/other', dst_b_mbuffer => '/usr/bin/mbuffer:9090'), 'dst_b'),
    'same host + port => same key, regardless of user and dataset');
isnt($zz->_dstMbufferEndpoint(
        eset(dst_a => 'backup1:pool/ds', dst_a_mbuffer => '/usr/bin/mbuffer:9090'), 'dst_a'),
    $zz->_dstMbufferEndpoint(
        eset(dst_b => 'backup1:pool/ds', dst_b_mbuffer => '/usr/bin/mbuffer:9091'), 'dst_b'),
    'same host, different port => different keys (may run together)');
isnt($zz->_dstMbufferEndpoint(
        eset(dst_a => 'backup1:pool/ds', dst_a_mbuffer => '/usr/bin/mbuffer:9090'), 'dst_a'),
    $zz->_dstMbufferEndpoint(
        eset(dst_b => 'backup2:pool/ds', dst_b_mbuffer => '/usr/bin/mbuffer:9090'), 'dst_b'),
    'different host, same port => different keys (may run together)');
is($zz->_dstMbufferEndpoint(
        eset(dst_a => 'pool/ds', dst_a_mbuffer => '/usr/bin/mbuffer:9090'), 'dst_a'),
    undef, 'local destination => no endpoint');
is($zz->_dstMbufferEndpoint(
        eset(dst_a => 'backup1:pool/ds', dst_a_mbuffer => '/usr/bin/mbuffer'), 'dst_a'),
    undef, 'remote destination without a port => no endpoint (plain SSH pipe)');
is($zz->_dstMbufferEndpoint(
        eset(dst_a => 'backup1:pool/ds', dst_a_mbuffer => 'off'), 'dst_a'),
    undef, 'destination mbuffer off => no endpoint');
is($zz->_dstMbufferEndpoint(
        eset(dst_a => 'backup1:pool/ds'), 'dst_a'),
    undef, 'no destination mbuffer property => no endpoint');
is($zz->_dstMbufferEndpoint(
        eset(src_mbuffer => 'off', dst_a => 'backup1:pool/ds', dst_a_mbuffer => '/usr/bin/mbuffer:9090'), 'dst_a'),
    undef, 'source mbuffer off => no port-to-port connection => no endpoint');

### Daemon shutdown reaches parallel destination workers ####################

# The pool forks one worker per destination from inside the send worker. The
# daemon's shutdown handler only knew snap_pid/send_pid, so those workers were
# left running as orphans. They are now published in dst_worker_pids and must be
# signalled (and reaped) by $killThemAll.
{
    my $sleeper = fork();
    die "fork failed: $!" unless defined $sleeper;
    if (!$sleeper) {
        exec('sleep', '60') or _exit(127);
    }

    my $victim = ZnapZend->new(
        backupSets => [
            { src => 'tank/with-workers', snap_pid => 0, send_pid => 0,
              dst_worker_pids => { $sleeper => 1 } },
            # A set that never ran a parallel pool has no dst_worker_pids at all.
            { src => 'tank/plain', snap_pid => 0, send_pid => 0 },
        ],
        logto => '/dev/null',
    );

    # $killThemAll ends in exit(), so run it in a throwaway child.
    my $handler = fork();
    die "fork failed: $!" unless defined $handler;
    if (!$handler) {
        $victim->$ZnapZend::killThemAll;
        _exit(0); # not reached
    }
    waitpid($handler, 0);
    is($? >> 8, 0, 'shutdown handler completes cleanly with and without destination workers');

    # The sleeper is our child, not the handler's, so reap it here.
    my $reaped = 0;
    for (1 .. 50) {
        $reaped = waitpid($sleeper, WNOHANG);
        last if $reaped;
        select(undef, undef, undef, 0.1);
    }
    is($reaped, $sleeper, 'shutdown handler terminated the parallel destination worker');
    is($? & 127, SIGTERM, '...with SIGTERM');
    kill('KILL', $sleeper) unless $reaped; # do not leak the sleeper on failure
}

done_testing;

1;
