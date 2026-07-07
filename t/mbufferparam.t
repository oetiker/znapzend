#!/usr/bin/env perl

# Tests for the configurable mbuffer params: extra arguments appended to the
# mbuffer stages of the send/receive pipeline (e.g. '-R 10M' to rate-limit).
# These are per-direction (src_mbuffer_param / dst_<key>_mbuffer_param), each
# inheriting from the general mbuffer_param; sendRecvSnapshots receives the two
# resolved values as its last two arguments. We run it in debug + noaction mode
# and inspect the command it would run.

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

use Test::More;

use_ok 'ZnapZend::ZFS';

# Run sendRecvSnapshots (no real action) and return the command it printed.
# Pass src/dst mbuffer executables ('off' to disable a stage) and the per-side
# extra params.
sub renderCmd {
    my %a = @_;
    my $zfs = ZnapZend::ZFS->new(debug => 1, noaction => 1);
    my $buf = '';
    {
        local *STDERR;
        open STDERR, '>', \$buf or die "cannot redirect STDERR: $!";
        eval {
            $zfs->sendRecvSnapshots(
                'tank/source',           # src dataset
                $a{dstDataSet} // 'backup/destination',  # dst dataset (local, or [user@]host:ds for SSH)
                'dst_0',                 # policy name
                $a{srcMbuffer} // 'off', # src mbuffer
                '1G',                    # src mbuffer size
                $a{dstMbuffer} // 'off', # dst mbuffer
                '1G',                    # dst mbuffer size
                qr/.*/,                  # snapshot filter
                undef,                   # lastSnapshotToSee
                undef,                   # allowDestRollback
                $a{srcParam} // '',      # src_mbuffer_param
                $a{dstParam} // '',      # dst_mbuffer_param
            );
        };
    }
    return $buf;
}

# The mbuffer stages of the rendered pipeline, in order (src first, then dst).
sub mbufferStages {
    my $cmd = shift;
    return ($cmd =~ m{(\Q$FindBin::Bin\E/mbuffer[^|]*)}g);
}

my $mb = "$FindBin::Bin/mbuffer";

# dst-side param only (src mbuffer off => single dst stage).
{
    my @stages = mbufferStages(renderCmd(dstMbuffer => $mb, dstParam => '-R 10M'));
    is(scalar @stages, 1, 'dst-only: one mbuffer stage');
    like($stages[0], qr/-R\b.*\b10M\b/s, 'dst_mbuffer_param appended to the dst mbuffer stage');
    like($stages[0], qr/-m\b.*-R\b/s, 'extra params come after the built-in -m <size>');
}

# src-side param only (dst mbuffer off => single src stage).
{
    my @stages = mbufferStages(renderCmd(srcMbuffer => $mb, srcParam => '-R 7M'));
    is(scalar @stages, 1, 'src-only: one mbuffer stage');
    like($stages[0], qr/-R\b.*\b7M\b/s, 'src_mbuffer_param appended to the src mbuffer stage');
}

# both stages, different params => independent per-direction values.
{
    my @stages = mbufferStages(renderCmd(
        srcMbuffer => $mb, dstMbuffer => $mb,
        srcParam => '-R 5M', dstParam => '-R 9M',
    ));
    is(scalar @stages, 2, 'src+dst: two mbuffer stages');
    like($stages[0], qr/\b5M\b/, 'src stage uses the src param (5M)');
    unlike($stages[0], qr/\b9M\b/, 'src stage does not get the dst param');
    like($stages[1], qr/\b9M\b/, 'dst stage uses the dst param (9M)');
    unlike($stages[1], qr/\b5M\b/, 'dst stage does not get the src param');
}

# empty params => no extras added.
{
    my @stages = mbufferStages(renderCmd(dstMbuffer => $mb, srcParam => '', dstParam => ''));
    is(scalar @stages, 1, 'empty params: dst stage still present');
    unlike($stages[0], qr/-R\b/, 'empty mbuffer_param adds no extra arguments');
}

# multiple params on one side are all passed through.
{
    my @stages = mbufferStages(renderCmd(dstMbuffer => $mb, dstParam => '-R 10M -W 1200'));
    like($stages[0], qr/-R\b.*\b10M\b/s, 'multiple params: -R 10M present');
    like($stages[0], qr/-W\b.*\b1200\b/s, 'multiple params: -W 1200 override present');
}

# Source-side mbuffer over SSH transport (remote destination, no mbuffer port):
# the rate-limit must be applied LOCALLY on the sender, ahead of the SSH hop.
# This is exactly the case the NixOS module previously could not express - it
# never set src_mbuffer, so it stayed 'off' and the param had no local stage to
# land on. With src_mbuffer a path, the local source stage must appear with -R.
{
    my $cmd = renderCmd(
        dstDataSet => 'root@backup.example.com:backup/destination',
        srcMbuffer => $mb, srcParam => '-R 75M',
        dstMbuffer => 'off',
    );
    my @stages = mbufferStages($cmd);
    is(scalar @stages, 1, 'ssh transport: a single (local source) mbuffer stage');
    like($stages[0], qr/-R\b.*\b75M\b/s, 'source rate-limit (-R 75M) applied locally over SSH');
    like($cmd, qr/\bssh\b.*\broot\@backup\.example\.com\b/s,
        'destination really transits SSH (no mbuffer port), so the cap is local');
}

done_testing;
