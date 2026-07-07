#!/usr/bin/env perl

# Tests for destination autoCreation, covering both the plain (unencrypted)
# and the raw/encrypted (--sendRaw) cases.
#
# The mock t/zfs offers every source a destination "dst_fail" => backup/destfail
# which is NOT a known dataset, i.e. a destination that does not yet exist. That
# is what exercises the autoCreation codepaths here. With ZNAPZENDTEST_ZFS_RECORD
# the mock logs every invoked subcommand so we can assert exactly what ran:
#   * plain  autoCreation: znapzend pre-creates the leaf with `zfs create`
#     and then `zfs recv`s into it.
#   * raw    autoCreation: znapzend must NOT pre-create the leaf (a raw encrypted
#     stream has to be received into a dataset that `zfs recv -w` creates itself,
#     so it becomes the encryption root); it must still `zfs recv` into it
#     instead of skipping the destination.

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

use File::Temp qw(tempfile);

unshift @INC, sub {
    my (undef, $filename) = @_;
    return () if $filename !~ /ZnapZend|znapzend/;
    if (my $found = (grep { -e $_ } map { "$_/$filename" } grep { !ref } @INC)[0] ) {
        local $/ = undef;
        open my $fh, '<', $found or die("Can't read module file $found\n");
        my $module_text = <$fh>;
        close $fh;

        # define everything in a sub, so Devel::Cover will DTRT
        $module_text =~ s/(.*?package\s+\S+)(.*)__END__/$1sub classWrapper {$2} classWrapper();/s;

        # uncomment testing code (makes send/recv run synchronously)
        $module_text =~ s/### RM_COMM_4_TEST ###//sg;

        # unhide private methods to avoid "Variable will not stay shared"
        $module_text =~ s/^[ \t]*my\s+(\S+\s*=\s*sub.*)$/our $1/gm;

        # filehandle on the scalar
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

# Run znapzend with the mock recording every invoked zfs subcommand.
# Returns ($ok, \@recordedLines).
sub runWithRecord {
    my @args = @_;
    my (undef, $recFile) = tempfile('znapzend-autocreation-XXXXXX', TMPDIR => 1, OPEN => 0);
    local $ENV{ZNAPZENDTEST_ZFS_RECORD} = $recFile;

    my $ok = runCommand(@args);

    my @lines;
    if (open(my $fh, '<', $recFile)) {
        @lines = <$fh>;
        close $fh;
        chomp @lines;
    }
    unlink $recFile;
    return ($ok, \@lines);
}

use Test::More;

use_ok 'ZnapZend';

#load program
@ARGV = qw(--help);
do 'znapzend' or die "ERROR: loading program znapzend $@\n";

### Plain (unencrypted) autoCreation #######################################
{
    my ($ok, $rec) = runWithRecord(qw(--runonce=tank/source --autoCreation));
    is($ok, 1, 'plain --autoCreation runonce succeeds');
    ok((grep { /^create\b.*backup\/destfail/ } @$rec),
        'plain --autoCreation creates the missing destination leaf with zfs create');
    ok((grep { /^recv\b.*backup\/destfail/ } @$rec),
        'plain --autoCreation receives into the destination');
}

### Raw / encrypted autoCreation (the regression being fixed) ##############
{
    my ($ok, $rec) = runWithRecord(qw(--runonce=tank/source --autoCreation --features=sendRaw));
    is($ok, 1, 'raw --autoCreation --features=sendRaw runonce succeeds');
    ok(!(grep { /^create\b.*backup\/destfail/ } @$rec),
        'raw --autoCreation does NOT pre-create the destination leaf');
    ok((grep { /^recv\b.*backup\/destfail/ } @$rec),
        'raw --autoCreation still receives into the destination (not skipped)');
    ok((grep { /^send\b.*\s-w(\s|$)/ } @$rec),
        'raw --autoCreation sends with -w (raw stream)');
}

# A failing `zfs create` must NOT break a raw autoCreation run, because the
# leaf is created by the receiving side, not by znapzend.
{
    local $ENV{ZNAPZENDTEST_ZFS_FAIL_create} = '1';
    is(runCommand(qw(--runonce=tank/source --autoCreation --features=sendRaw)), 1,
        'raw --autoCreation survives a failing zfs create (never calls it)');
}

### Raw send WITHOUT autoCreation: missing destination is skipped cleanly ###
{
    my ($ok, $rec) = runWithRecord(qw(--runonce=tank/source --features=sendRaw));
    is($ok, 1, 'raw --sendRaw without autoCreation succeeds');
    ok(!(grep { /^create\b.*backup\/destfail/ } @$rec),
        'raw without autoCreation does not create the missing destination');
    ok(!(grep { /^recv\b.*backup\/destfail/ } @$rec),
        'raw without autoCreation skips the missing destination (no recv)');
}

done_testing;
