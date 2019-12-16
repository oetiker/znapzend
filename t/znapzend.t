#!/usr/bin/env perl

use strict;
use warnings;

use FindBin;
$ENV{PATH} = "$FindBin::Bin:$ENV{PATH}";
my $buildDir;

BEGIN {
    $buildDir = shift @ARGV // "$FindBin::Bin/../";
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

use_ok 'ZnapZend';

#load program
@ARGV = qw(--help);
do 'znapzend' or die "ERROR: loading program znapzend\n";

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

# Do not test after daemonize, to avoid conflicts
is (runCommand_canThrow(qw(--daemonize --debug),'--features=oracleMode,recvu',
    qw(--pidfile=znapzend.pid)), 1, 'znapzend --daemonize #1');
#...but do try to cover these error codepaths ;)
eval { is (runCommand_canThrow(qw(--daemonize --debug),'--features=compressed',
    qw(--pidfile=znapzend2.pid)), 1, 'znapzend --daemonize #2'); };
eval { is (runCommand_canThrow(qw(--daemonize --debug),'-n',
    qw(--pidfile=znapzend.pid)), 1, 'znapzend --daemonize #3'); };

done_testing;

1;
