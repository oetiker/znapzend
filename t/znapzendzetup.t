#!/usr/bin/env perl

use strict;
use warnings;

use FindBin;
$ENV{PATH} = $FindBin::RealBin.':'.$ENV{PATH};
my $buildDir;

BEGIN {
    $buildDir = shift @ARGV // $FindBin::RealBin."/../";
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

    if ($@) {
        # Presumably a die() handler caught something
        print STDERR "EXCEPTION: " . $@ . "\n";
        return 0;
    };

    # Return "true" if not failed :)
    1;
}

use Test::More;

use_ok 'ZnapZend';

#load program
@ARGV = qw(help);
do 'znapzendzetup' or die "ERROR: loading program znapzendzetup $@\n";

is (runCommand('help'), 1, 'znapzendzetup help');

is (runCommand('list'), 1, 'znapzendzetup list');

is (runCommand(qw(create SRC 1h=>10min tank/source),
    qw(DST 1h=>10min backup/destination)), 1, 'znapzendzetup create');

is (runCommand(qw(edit SRC 1h=>10min tank/source),
    qw(DST:0 1h=>10min backup/destination)), 1, 'znapzendzetup edit');

is (runCommand(qw(edit SRC 33asdf=>10min tank/source),
    qw(DST:0 1h=>10min backup/destination)), 0, 'znapzendzetup edit');

is (runCommand(qw(edit SRC 33sec=>10min tank/source),
    qw(DST:0 1h=>10min backup/destination)), 0, 'znapzendzetup edit');

is (runCommand(qw(edit tank/source)), 1, 'znapzendzetup edit src_dataset');

is (runCommand(qw(create --donotask --tsformat=%Y%m%d-%H%M%S SRC 1h=>10min tank/source),
    qw(DST 1h=>10min backup/destination)), 1, 'znapzendzetup create --donotask');
is (runCommand(qw(create --donotask --dst-concurrency SRC 1h=>10min tank/source),
    qw(DST 1h=>10min backup/destination)), 1, 'znapzendzetup create --dst-concurrency (all destinations)');
is (runCommand(qw(create --donotask --dst-concurrency=2 SRC 1h=>10min tank/source),
    qw(DST 1h=>10min backup/destination)), 1, 'znapzendzetup create --dst-concurrency');
is (runCommand(qw(create --donotask --dst-concurrency=0 SRC 1h=>10min tank/source),
    qw(DST 1h=>10min backup/destination)), 0, 'znapzendzetup create --dst-concurrency invalid');

# Opt-out: --dst-concurrency=off disables parallelism (create and edit).
is (runCommand(qw(create --donotask --dst-concurrency=off SRC 1h=>10min tank/source),
    qw(DST 1h=>10min backup/destination)), 1, 'znapzendzetup create --dst-concurrency=off (explicit opt-out)');
is (runCommand(qw(edit --donotask --dst-concurrency=off SRC 1h=>10min tank/source),
    qw(DST:0 1h=>10min backup/destination)), 1, 'znapzendzetup edit --dst-concurrency=off (opt-out)');
# An explicit but empty value is an error, not a silent enable-all.
is (runCommand(qw(create --donotask --dst-concurrency= SRC 1h=>10min tank/source),
    qw(DST 1h=>10min backup/destination)), 0, 'znapzendzetup create --dst-concurrency= (empty value) fails');
# A malformed value is rejected identically on create AND edit (regression: the
# edit path used to silently accept it as "all destinations").
is (runCommand(qw(create --donotask --dst-concurrency=abc SRC 1h=>10min tank/source),
    qw(DST 1h=>10min backup/destination)), 0, 'znapzendzetup create --dst-concurrency=abc (non-numeric) fails');
is (runCommand(qw(edit --donotask --dst-concurrency=abc SRC 1h=>10min tank/source),
    qw(DST:0 1h=>10min backup/destination)), 0, 'znapzendzetup edit --dst-concurrency=abc (non-numeric) fails');
is (runCommand(qw(edit --donotask --dst-concurrency=0 SRC 1h=>10min tank/source),
    qw(DST:0 1h=>10min backup/destination)), 0, 'znapzendzetup edit --dst-concurrency=0 fails');

# extractDstConcurrencyOption parses only the documented forms and never
# consumes a following positional argument as the value (regression: a bare
# flag used to swallow an immediately-following plain-digit token).
{
    my @a = ('--dst-concurrency', '512', 'SRC');
    my ($seen, $val) = extractDstConcurrencyOption(\@a);
    is ($seen, 1, 'extract: bare --dst-concurrency is seen');
    is ($val, undef, 'extract: bare --dst-concurrency has no value');
    is_deeply (\@a, ['512', 'SRC'], 'extract: a following numeric positional is NOT stolen');

    @a = ('--dst-concurrency=3');
    ($seen, $val) = extractDstConcurrencyOption(\@a);
    is ($val, 3, 'extract: =<count> returns the count');

    @a = ('--dst-concurrency=off');
    ($seen, $val) = extractDstConcurrencyOption(\@a);
    is ($val, 'off', 'extract: =off returns off');

    @a = ('--dst-concurrency=');
    my $survived = eval { extractDstConcurrencyOption(\@a); 1 };
    ok (!$survived, 'extract: an empty =value dies rather than silently enabling');
}

# Regression: a destination literally named "concurrency" (DST:concurrency) is
# stored as the key dst_concurrency. Before the concurrency properties were
# renamed out of the dst_<key> namespace this collided with the numeric
# dst_concurrency validation and hard-failed. It must now be treated as an
# ordinary destination and validate cleanly. (Copilot C3/C4)
is (runCommand(qw(create --donotask SRC 1h=>10min tank/source),
    qw(DST:concurrency 1h=>10min backup/destination)), 1,
    'znapzendzetup create with a destination named "concurrency" (no property-name collision)');
is (runCommand(qw(edit --donotask SRC 1h=>10min tank/source),
    qw(DST:concurrency 1h=>10min backup/destination)), 1,
    'znapzendzetup edit with a destination named "concurrency" (no property-name collision)');
# Opt-in parallelism and a destination named "concurrency" coexist.
is (runCommand(qw(create --donotask --dst-concurrency=2 SRC 1h=>10min tank/source),
    qw(DST:concurrency 1h=>10min backup/destination),
    qw(DST:other 1h=>10min backup/other)), 1,
    'znapzendzetup create --dst-concurrency=2 alongside a destination named "concurrency"');

is (runCommand(qw(create --donotask), '--mbufferparam=-R 10M', qw(SRC 1h=>10min tank/source),
    qw(DST 1h=>10min backup/destination)), 1, 'znapzendzetup create with a valid --mbufferparam');

is (runCommand(qw(create --donotask), "--mbufferparam='-R 10M", qw(SRC 1h=>10min tank/source),
    qw(DST 1h=>10min backup/destination)), 0, 'znapzendzetup create with unbalanced --mbufferparam quoting fails');

# --- per-direction mbuffer params via the positional SRC/DST grammar ---------

# Direct unit test of the positional slots added to parseArguments().
{
    my $bs = parseArguments(['SRC', '1h=>10min', 'tank/source',
        '/usr/bin/mbuffer', '1G', '-R 75M',
        'DST:nas', '1h=>10min', 'backup/destination', 'off', 'off',
        '/usr/bin/mbuffer', '1G', '-R 5M']);
    is($bs->{src_mbuffer},          '/usr/bin/mbuffer', 'positional src_mbuffer path parsed');
    is($bs->{src_mbuffer_size},     '1G',               'positional src_mbuffer_size parsed');
    is($bs->{src_mbuffer_param},    '-R 75M',           'positional src_mbuffer_param parsed');
    is($bs->{dst_nas_mbuffer},      '/usr/bin/mbuffer', 'positional dst_<key>_mbuffer path parsed');
    is($bs->{dst_nas_mbuffer_size}, '1G',               'positional dst_<key>_mbuffer_size parsed');
    is($bs->{dst_nas_mbuffer_param},'-R 5M',            'positional dst_<key>_mbuffer_param parsed');
}

# An empty trailing param slot is a placeholder and is not stored.
{
    my $bs = parseArguments(['SRC', '1h=>10min', 'tank/source', '/usr/bin/mbuffer', '1G', '']);
    ok(!exists $bs->{src_mbuffer_param}, 'empty positional src_mbuffer_param is not stored');
    is($bs->{src_mbuffer_size}, '1G', 'preceding positional (size) still parsed');
}

my $mbpath = "$FindBin::Bin/mbuffer";

is (runCommand('create', '--donotask', 'SRC', '1h=>10min', 'tank/source', $mbpath, '1G', '-R 75M',
    'DST', '1h=>10min', 'backup/destination', 'off', 'off', $mbpath, '1G', '-R 5M'), 1,
    'znapzendzetup create with positional per-direction mbuffer params');

is (runCommand('edit', '--donotask', 'SRC', '1h=>10min', 'tank/source', $mbpath, '1G', '-R 75M',
    'DST:0', '1h=>10min', 'backup/destination'), 1,
    'znapzendzetup edit with positional src_mbuffer_param');

is (runCommand('create', '--donotask', 'SRC', '1h=>10min', 'tank/source', $mbpath, '1G', "'-R 75M",
    'DST', '1h=>10min', 'backup/destination'), 0,
    'znapzendzetup create with unbalanced positional src_mbuffer_param quoting fails');

is (runCommand(qw(edit --donotask --tsformat=%Y%m%d-%H%M%S SRC 1h=>10min tank/source),
    qw(DST:0 1h=>10min backup/destination)), 1, 'znapzendzetup edit --donotask');
is (runCommand(qw(edit --donotask --dst-concurrency SRC 1h=>10min tank/source),
    qw(DST:0 1h=>10min backup/destination)), 1, 'znapzendzetup edit --dst-concurrency (all destinations)');
is (runCommand(qw(edit --donotask --dst-concurrency=3 SRC 1h=>10min tank/source),
    qw(DST:0 1h=>10min backup/destination)), 1, 'znapzendzetup edit --dst-concurrency');
is (runCommand(qw(edit --donotask --dst-concurrency=0 SRC 1h=>10min tank/source),
    qw(DST:0 1h=>10min backup/destination)), 0, 'znapzendzetup edit --dst-concurrency invalid');

is (runCommand(qw(enable tank/source)), 1, 'znapzendzetup enable');

is (runCommand(qw(disable tank/source)), 1, 'znapzendzetup disable');

is (runCommand(qw(delete tank/source)), 1, 'znapzendzetup delete');

is (runCommand(qw(delete --dst='0' tank/source)), 1, 'znapzendzetup delete destination');

{
    local *STDOUT;
    open STDOUT, ">./dump.dmp";
    is (runCommand(qw(export tank/source)), 1, 'znapzendzetup export');
}

is (runCommand(qw(import tank/source ./dump.dmp)), 1, 'znapzendzetup import');
is (runCommand(qw(import --write tank/source ./dump.dmp)), 1, 'znapzendzetup import --write');

# Cover various codepaths for successes and failures...
# Destination can be passed by number (N) or zfs attr name (dst_N)
# TODO? Add by target dataset value as the more user-meaningful variant?
is (runCommand(qw(enable-dst tank/source dst_0)), 1, 'znapzendzetup enable-dst tank/source dst_0 - succeeds');
is (runCommand(qw(disable-dst tank/source dst_0)), 1, 'znapzendzetup disable-dst tank/source dst_0 - succeeds');
is (runCommand(qw(enable-dst tank/source DST:0)), 1, 'znapzendzetup enable-dst tank/source DST:0 - succeeds');
is (runCommand(qw(disable-dst tank/source DST:0)), 1, 'znapzendzetup disable-dst tank/source DST:0 - succeeds');
is (runCommand(qw(enable-dst tank/source 0)), 1, 'znapzendzetup enable-dst tank/source 0 - succeeds (0=>dst_0)');
is (runCommand(qw(disable-dst tank/source 0)), 1, 'znapzendzetup disable-dst tank/source 0 - succeeds (0=>dst_0)');
is (runCommand(qw(enable-dst tank/dest-disabled dst_0)), 1, 'znapzendzetup enable-dst tank/dest-disabled dst_0 - succeeds (processing codepath with dst_0_enabled present in zfs args)');
is (runCommand(qw(disable-dst tank/dest-disabled dst_0)), 1, 'znapzendzetup disable-dst tank/dest-disabled dst_0 - succeeds (processing codepath with dst_0_enabled present in zfs args)');

# Destination-management fails for a number of expected reasons
is (runCommand(qw(enable-dst tank/source dst_1_badkey)), 0, 'znapzendzetup enable-dst tank/source dst_1_badkey - fails (arg is not a dst ID pattern)');
is (runCommand(qw(disable-dst tank/source dst_1_badkey)), 0, 'znapzendzetup disable-dst tank/source dst_1_badkey - fails (arg is not a dst ID pattern)');
is (runCommand(qw(enable-dst tank/source 1)), 0, 'znapzendzetup enable-dst tank/source 1 - fails (no 1=>dst_1 there)');
is (runCommand(qw(disable-dst tank/source 1)), 0, 'znapzendzetup disable-dst tank/source 1 - fails (no 1=>dst_1 there)');
is (runCommand(qw(enable-dst tank/sourcemissing dst_whatever)), 0, 'znapzendzetup enable-dst tank/sourcemissing dst_whatever - fails (no such dataset)');
is (runCommand(qw(disable-dst tank/sourcemissing dst_whatever)), 0, 'znapzendzetup disable-dst tank/sourcemissing dst_whatever - fails (no such dataset)');
is (runCommand(qw(enable-dst tank/sourcemissing)), 0, 'znapzendzetup enable-dst tank/sourcemissing - fails (bad arg list)');
is (runCommand(qw(disable-dst tank/sourcemissing)), 0, 'znapzendzetup disable-dst tank/sourcemissing - fails (bad arg list)');

# This one calls "zfs list -r" and then many times "zfs get"
is (runCommand(qw(list), '--features=lowmemRecurse,sudo', qw(--debug -r tank/source)), 1, 'znapzendzetup list --features=lowmemRecurse,sudo --debug -r tank/source');
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

# Code-cover parsing of bad argument lists
is (runCommand(), 0, 'znapzendzetup <no main opt> - fails');
is (runCommand(qw(bogusMainOpt)), 0, 'znapzendzetup <bogus main opt> - fails');

is (runCommand(qw(delete)), 0, 'znapzendzetup delete <no src arg> - fails');
is (runCommand(qw(enable)), 0, 'znapzendzetup enable <no src arg> - fails');
is (runCommand(qw(disable)), 0, 'znapzendzetup disable <no src arg> - fails');
is (runCommand(qw(enable-dst)), 0, 'znapzendzetup enable-dst <no src arg> <no dst arg> - fails');
is (runCommand(qw(disable-dst)), 0, 'znapzendzetup disable-dst <no src arg> <no dst arg> - fails');
is (runCommand(qw(export)), 0, 'znapzendzetup export <no src arg> - fails');

done_testing;

1;
