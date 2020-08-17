#!/usr/bin/env perl

use strict;
use warnings;

use FindBin;
$ENV{PATH} = "$FindBin::Bin:$ENV{PATH}";
my $buildDir;

BEGIN {
    $buildDir = shift @ARGV // "$FindBin::Bin/../";
}

# Track child PIDs spawned by test
our @test_arr_children = ();
sub test_arr_children { \@test_arr_children };

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
        $module_text =~ s/### RM_COMM_4_TEST(|_main) ###//sg;

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

    return main();
}

### use threads;
use Test::More;
use Test::Exception;
use Test::SharedFork; ### NOTE: Conflicts with ithreads

use POSIX ":sys_wait_h";

# Succeed the Test::More part...
use_ok 'ZnapZend';

#load program
@ARGV = qw(--help);
do 'znapzend' or die "ERROR: loading program znapzend\n";

# For tests below we run the real forking and daemonization and test how it
# behaves. Thanks to Test::SharedFork above these are counted correctly -
# mind that after forking inside znapzend code, we have two outcomes in log.
# Note that for child processes the test harness intercepts and hides their
# STDERR and STDOUT streams, and the parent process with many tests runs
# quickly. The tests for pidfile conflict detection (#1b and #3) rely on
# this so are a bit prone to race condition like cases.
# As for exit codes, we expect "1" for normal completion of a daemon (which
# runs one loop for tests), or "254" for parent process "fake-exit()", or
# "255" for pre-forking "fake-die()" due to pidfile conflict. Due to this
# tests below expect "(1 or 254)" for normal daemonization or "(1 or 255)"
# where we accept that pidfile conflict might not happen in fact.

# Allow testing forkedTest() itself :)
sub myprint {
    print STDERR "=====> '" . join(',', @_) . "'\n";
    return 1;
}

sub forkedTest {
    # Args are similar to those passed into Test->is_num():
    # $0 = expected code for child (primary worker)
    # $1 = expected code for parent (dies just after fork, or in sanity checks before)
    # $2 = comment to print about the test
    # $3 = routine to use for testing
    # @4 = args to that call (array)
    my ($expResChild) = $_[0]; # can be undef, number or array ref
    my ($expResParent) = $_[1];
    my ($expTxt) = $_[2];
    my ($expCall) = $_[3];
    my (@expCallArgs) = @{$_[4]};

    # Usually forked/daemonized subprocess can return "ok"/"not ok" twice,
    # for parent and child, so we use a trick to run the tested routine
    # first, and then report on how that went in child and parent processes
    # (assuming the child does fork).
    my $testPID = $$;

    # Small debug of test routine
    print STDERR "=== BEGIN test in parent $$ before forking: '$expTxt'\n";
    myprint(@expCallArgs);

    # This can fork
    my $res = &{$expCall}(@expCallArgs);

    if ( $$ != $testPID ) {
        # Make a test verdict for one leg of the forked tests, the daemon
        if (ref($expResChild) eq 'ARRAY') {
            print STDERR "=== INTERPRET test in child $$ (res=$res, exp in '" . join(" or ", @$expResChild) . "'): '$expTxt'\n";
            ok( scalar(grep{$res == $_} @$expResChild) == 1, $expTxt . " (child)" );
        } else {
            print STDERR "=== INTERPRET test in child $$ (res=$res, exp=$expResChild): '$expTxt'\n";
            is($res, $expResChild, $expTxt . " (child)" );
        }
        print STDERR "=== ENDED test in child with $res: '$expTxt'\n";
        exit();
    } else {
        # Make a test verdict for parent which is usually nearly no-op
        if (ref($expResParent) eq 'ARRAY') {
            print STDERR "=== INTERPRET test in parent $$ (res=$res, exp in '" . join(" or ", @$expResParent) . "'): '$expTxt'\n";
            ok( scalar(grep{$res == $_} @$expResParent) == 1, $expTxt . " (parent)" );
        } else {
            print STDERR "=== INTERPRET test in parent $$ (res=$res, exp=$expResParent): '$expTxt'\n";
            is($res, $expResParent, $expTxt . " (parent)" );
        }
    }
}


#    forkedTest (undef, 1, 'Testing test framework',
#        \&myprint, [ '--daemonize', '--debug', '--features=oracleMode,recvu',
#        '--pidfile=znapzend.pid' ] );

# Check that pidfile conflict detection works
    forkedTest (1, 254, 'Daemons be here: znapzend --daemonize #1a',
        \&runCommand_canThrow, [ '--daemonize', '--debug', '--features=oracleMode,recvu',
        '--pidfile=znapzend.pid' ] );

    # IF daemon #1 is still alive, we can check if we conflict in pidfile
    # (255 before forking) or work normally (1 in child, 254 in parent):
    my @expResConflict = (255, 254);
    forkedTest (1, \@expResConflict, 'Daemons be here: znapzend --daemonize #1b',
        \&runCommand_canThrow, [ '--daemonize', '--debug', '-n', '--pidfile=znapzend.pid' ] );

# There should be no conflict for different PID file though
# (Note in real life two znapzends not given paths to work on
# would discover same datasets and policies and conflict while
# sending/receiving stuff)
    forkedTest (1, 254, 'Daemons be here: znapzend --daemonize #2',
        \&runCommand_canThrow, [ '--daemonize', '--debug', '--features=compressed', '--pidfile=znapzend2.pid' ] );

# ASSUMPTION: Eval and time should cover up the users for that pidfile
# For coverage, test also the daemon mode doing nothing R/W wise
    forkedTest (1, \@expResConflict, 'Daemons be here: znapzend --daemonize #3',
        \&runCommand_canThrow, [ '--daemonize', '-n', '--pidfile=znapzend.pid' ] );

print STDERR "=== Parent test launcher is done, waiting for child daemons...\n";

# From https://perldoc.perl.org/functions/waitpid.html suggestions:
#my $kid;
#do {
#    $kid = waitpid(-1, WNOHANG);
#} while $kid > 0;

while (scalar(@test_arr_children)) {
    ####SPAMALOT### print STDERR "=== REMAINS : " . @test_arr_children . " : " . join (', ', @test_arr_children) . "\n";
    for my $kid (@test_arr_children) {
        if ( $kid == waitpid($kid, WNOHANG) ) {
            print STDERR "=== Parent reaped child daemon PID=$kid\n";
            @test_arr_children = grep { $kid != $_ } @test_arr_children;
        }
    }
}

done_testing();

1;
