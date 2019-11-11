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
    return () if $filename !~ /ZnapZend|znapzendzetup/;
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
    my $mainOpt = shift;
    @ARGV = @_;

    eval { main($mainOpt); };
    return 0 if $@; # Presumably die() handler caught something
    1;
}

use Test::More;

use_ok 'ZnapZend';

#load program
@ARGV = qw(help);
do 'znapzendzetup' or die "ERROR: loading program znapzendzetup\n";

is (runCommand('help'), 1, 'znapzendzetup help');

is (runCommand('list'), 1, 'znapzendzetup list');

is (runCommand(qw(create SRC 1h=>10min tank/source),
    qw(DST 1h=>10min backup/destination)), 1, 'znapzendzetup create');

is (runCommand(qw(edit SRC 1h=>10min tank/source),
    qw(DST:0 1h=>10min backup/destination)), 1, 'znapzendzetup edit');

is (runCommand(qw(edit tank/source)), 1, 'znapzendzetup edit src_dataset');

is (runCommand(qw(create --donotask --tsformat=%Y%m%d-%H%M%S SRC 1h=>10min tank/source),
    qw(DST 1h=>10min backup/destination)), 1, 'znapzendzetup create --donotask');

is (runCommand(qw(edit --donotask --tsformat=%Y%m%d-%H%M%S SRC 1h=>10min tank/source),
    qw(DST:0 1h=>10min backup/destination)), 1, 'znapzendzetup edit --donotask');

is (runCommand(qw(enable tank/source)), 1, 'znapzendzetup enable');

is (runCommand(qw(disable tank/source)), 1, 'znapzendzetup disable');

is (runCommand(qw(delete tank/source)), 1, 'znapzendzetup delete');

is (runCommand(qw(delete --dst='0' tank/source)), 1, 'znapzendzetup delete destination');

{
    local *STDOUT;
    open STDOUT, ">./dump.dmp";
    is (runCommand(qw(export tank/source)), 1, 'znapzendzetup export');
}

is(runCommand(qw(import tank/source ./dump.dmp)), 1, 'znapzendzetup import');
is(runCommand(qw(import --write tank/source ./dump.dmp)), 1, 'znapzendzetup import --write');

# This one calls "zfs list -r" and then many times "zfs get"
is (runCommand(qw(list --features=lowmemRecurse,sudo --debug -r tank/source)), 1, 'znapzendzetup list --features=lowmemRecurse,sudo --debug -r tank/source');
# This one calls "zfs get -r"
is (runCommand(qw(list --debug --recursive tank/source)), 1, 'znapzendzetup list --debug --recursive tank/source');
# This one should follow a codepath of undefined "dataSet" to show and so all datasets known to zfs (mock)
is (runCommand(qw(list)), 1, 'znapzendzetup list');
# This one should follow a codepath of a dataset array with several entries
is (runCommand(qw(list tank/source tank/anothersource)), 1, 'znapzendzetup list two trees');
is (runCommand(qw(list --features=lowmemRecurse -r tank/source tank/anothersource)), 1, 'znapzendzetup list lowmem two trees');

is (runCommand(qw(list --features=zfsGetType -r tank/source)), 1, 'znapzendzetup list with zfsGetType feature and new zfs - succeeds');
is (runCommand(qw(list --features=zfsGetType --inherited -r tank/source)), 1, 'znapzendzetup list with zfsGetType feature and --inherited and new zfs - succeeds');
$ENV{'ZNAPZENDTEST_ZFS_GET_TYPE_UNHANDLED'} = '1';
is (runCommand(qw(list --features=zfsGetType -r tank/source)), 0, 'znapzendzetup list with zfsGetType feature and old zfs - fails');
is (runCommand(qw(list --features=zfsGetType --inherited -r tank/source)), 0, 'znapzendzetup list with zfsGetType feature and --inherited and old zfs - fails');
$ENV{'ZNAPZENDTEST_ZFS_GET_TYPE_UNHANDLED'} = undef;

# Enabled dataset with an inherited plan:
is (runCommand(qw(list --debug --inherited tank/source/child)), 1, 'znapzendzetup list --inherited tank/source/child succeeds');
is (runCommand(qw(list --debug --recursive --inherited tank/source/child)), 1, 'znapzendzetup list --inherited -r tank/source/child succeeds (finds only it, not the grandchild)');
is (runCommand(qw(list --debug --recursive --inherited tank)), 1, 'znapzendzetup list --inherited -r tank succeeds (finds only source and anothersource, not the descendants)');
is (runCommand(qw(list --debug --recursive --inherited tank tank/source/child)), 1, 'znapzendzetup list --inherited -r tank tank/source/child succeeds (finds source and anothersource via recursion, and the explicit tank/source/child, but not other descendants)');

# These should fail
is (runCommand(qw(list --debug --inherited tank)), 0, 'znapzendzetup list --inherited tank (non-recursive) fails');
is (runCommand(qw(list tank/source/child)), 0, 'znapzendzetup list tank/source/child (no inheritance) fails');
is (runCommand(qw(list --recursive tank/source/child)), 0, 'znapzendzetup list -r tank/source/child (no inheritance, no descendants with a local config) fails');

is (runCommand(qw(list --debug --inherited backup)), 0, 'znapzendzetup list --inherited backup (non-recursive) fails');
is (runCommand(qw(list --debug --recursive backup)), 0, 'znapzendzetup list --recursive backup fails');
is (runCommand(qw(list --debug --inherited --recursive backup)), 0, 'znapzendzetup list --inherited --recursive backup fails');
is (runCommand(qw(list --debug backup)), 0, 'znapzendzetup list backup (non-recursive) fails');

is (runCommand(qw(list missingpool)), 0, 'znapzendzetup list missingpool');
is (runCommand(qw(list -r missingpool)), 0, 'znapzendzetup list -r missingpool');
is (runCommand(qw(list --features=lowmemRecurse missingpool)), 0, 'znapzendzetup list --features=lowmemRecurse missingpool');
is (runCommand(qw(list --features=lowmemRecurse -r missingpool)), 0, 'znapzendzetup list --features=lowmemRecurse -r missingpool');
is (runCommand(qw(export missingpool)), 0, 'znapzendzetup export missingpool');

$ENV{'ZNAPZENDTEST_ZFS_FAIL_list'} = '1';
is (runCommand(qw(list)), 0, 'znapzendzetup list');
$ENV{'ZNAPZENDTEST_ZFS_FAIL_list'} = undef;

done_testing;

1;

