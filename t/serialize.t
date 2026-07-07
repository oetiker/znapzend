#!/usr/bin/env perl

# Tests for send serialization (--maxConcurrentSends / --serialize).
#
# The send/receive concurrency limit is implemented by a small queueing gate
# (ZnapZend::_claimSendSlot / _releaseSendSlot) that sendWorker consults before
# forking. We test that gate directly and deterministically here - it is the
# part that actually enforces the limit - rather than relying on fragile timing
# of real parallel forks. A couple of end-to-end smoke runs confirm the new CLI
# options are accepted and validated.

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

sub runCommand {
    @ARGV = @_;
    eval { main(); };
    if ($@) {
        print STDERR "EXCEPTION: " . $@ . "\n";
        return 0;
    };
    return 1;
}

use Test::More;

use_ok 'ZnapZend';

#load program (defines main())
@ARGV = qw(--help);
do 'znapzend' or die "ERROR: loading program znapzend $@\n";

### The concurrency gate ###################################################

# Default: unlimited, no queueing.
{
    my $zz = ZnapZend->new;
    is($zz->maxConcurrentSends, 0, 'maxConcurrentSends defaults to 0 (unlimited)');
    is($zz->_activeSends, 0, 'no active sends initially');
    ok($zz->_claimSendSlot({src => 'p/a'}, 1), 'unlimited: claim always succeeds (1)');
    ok($zz->_claimSendSlot({src => 'p/b'}, 2), 'unlimited: claim always succeeds (2)');
    ok($zz->_claimSendSlot({src => 'p/c'}, 3), 'unlimited: claim always succeeds (3)');
    is(scalar @{$zz->_sendQueue}, 0, 'unlimited: nothing is ever queued');
}

# A finite limit queues the overflow and dispatches it FIFO as slots free up.
{
    my $zz = ZnapZend->new(maxConcurrentSends => 2);
    my @bs = map { +{ src => "pool/set$_" } } 0 .. 3;

    ok($zz->_claimSendSlot($bs[0], 10), 'set0 claims slot 1 of 2');
    ok($zz->_claimSendSlot($bs[1], 11), 'set1 claims slot 2 of 2');
    is($zz->_activeSends, 2, 'two sends active (at the limit)');

    ok(!$zz->_claimSendSlot($bs[2], 12), 'set2 is queued (limit reached)');
    ok(!$zz->_claimSendSlot($bs[3], 13), 'set3 is queued');
    is($zz->_activeSends, 2, 'still two active while two wait');
    is(scalar @{$zz->_sendQueue}, 2, 'two sends queued');

    # set0 finishes -> next queued (set2) should be handed back, FIFO.
    my $next = $zz->_releaseSendSlot;
    is($zz->_activeSends, 1, 'a slot is freed on release');
    is_deeply($next, [$bs[2], 12], 'release dispatches the oldest queued send (FIFO)');

    # Caller dispatches it (sendWorker re-claims the slot).
    ok($zz->_claimSendSlot(@$next), 'dispatched send re-claims the slot');
    is($zz->_activeSends, 2, 'back at the limit');
    is(scalar @{$zz->_sendQueue}, 1, 'one send still queued');

    # set1 finishes -> set3 dispatched.
    my $next2 = $zz->_releaseSendSlot;
    is_deeply($next2, [$bs[3], 13], 'second queued send dispatched in order');
    $zz->_claimSendSlot(@$next2);
    is(scalar @{$zz->_sendQueue}, 0, 'queue drained');

    # Nothing left to dispatch as the remaining sends finish.
    is($zz->_releaseSendSlot, undef, 'release returns undef when queue is empty');
    is($zz->_releaseSendSlot, undef, 'release stays undef and never underflows');
    is($zz->_activeSends, 0, 'active send count returns to zero');
}

# --serialize behaves as maxConcurrentSends == 1.
{
    my $zz = ZnapZend->new(maxConcurrentSends => 1);
    ok($zz->_claimSendSlot({src => 'p/x'}, 1), 'serialize: first send runs');
    ok(!$zz->_claimSendSlot({src => 'p/y'}, 2), 'serialize: second send waits');
    ok(!$zz->_claimSendSlot({src => 'p/z'}, 3), 'serialize: third send waits');
    is($zz->_activeSends, 1, 'serialize: exactly one send active');
    is(scalar @{$zz->_sendQueue}, 2, 'serialize: the rest are queued');
}

# A queued send is flagged 'send_queued' so snapWorker won't re-enqueue the same
# set (in daemon mode, where its send_pid stays 0 while waiting); the flag clears
# once the set claims a slot.
{
    my $zz = ZnapZend->new(maxConcurrentSends => 1);
    my $a = { src => 'pool/a' };
    my $b = { src => 'pool/b' };

    ok($zz->_claimSendSlot($a, 1), 'set a starts (claims the slot)');
    ok(!$a->{send_queued}, 'a running set is not flagged send_queued');

    ok(!$zz->_claimSendSlot($b, 2), 'set b is queued (at the limit)');
    ok($b->{send_queued}, 'a queued set is flagged send_queued');

    # set a finishes; b is dispatched and re-claims, clearing its flag.
    my $next = $zz->_releaseSendSlot;
    is_deeply($next, [$b, 2], 'b is the next queued set to dispatch');
    $zz->_claimSendSlot(@$next);
    ok(!$b->{send_queued}, 'a dispatched set clears its send_queued flag');
}

### End-to-end CLI handling ################################################

is(runCommand(qw(--runonce=tank/source --serialize)), 1,
    'znapzend --serialize --runonce=tank/source succeeds');
is(runCommand(qw(--runonce=tank/source --maxConcurrentSends=2)), 1,
    'znapzend --maxConcurrentSends=2 --runonce=tank/source succeeds');
is(runCommand(qw(--runonce=tank/source --maxConcurrentSends=0)), 1,
    'znapzend --maxConcurrentSends=0 (unlimited) --runonce=tank/source succeeds');
is(runCommand(qw(--runonce=tank/source --maxConcurrentSends=-1)), 0,
    'znapzend --maxConcurrentSends=-1 fails (must be non-negative)');

done_testing;
