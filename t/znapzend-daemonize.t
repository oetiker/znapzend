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

### use threads;
use Test::Builder;
use Test::More;
use Test::Exception;

# Succeed the Test::More part...
use_ok 'ZnapZend';

#load program
@ARGV = qw(--help);
do 'znapzend' or die "ERROR: loading program znapzend\n";


# Forked/daemonized subprocess can return "ok"/"not ok" twice, for parent
# and child, so we use a Test::Builder to disable numbering the tests which
# otherwise confuses the runner.
my $Test = Test::Builder->create;
$Test->use_numbers(0);

# We do not predefine a test count
$Test->no_plan;

# We want to see helpful blurbs from the test suite
$Test->no_header(0);
$Test->no_ending(0);
$Test->no_diag(0);


# Do not run usual tests after daemonize, to avoid conflicts...
eval {
    $Test->is_num (1, runCommand_canThrow(qw(--daemonize --debug),'--features=oracleMode,recvu',
        qw(--pidfile=znapzend.pid)), 'Daemons be here: znapzend --daemonize #1a');

    #...but do try to cover these error codepaths ;)
    # IF daemon #1 is still alive, we can check if we conflict in pidfile:
    $Test->is_num (1, runCommand_canThrow(qw(--daemonize),'-n',
        qw(--pidfile=znapzend.pid)), 'Daemons be here: znapzend --daemonize #1b');
};

# There should be no conflict for different PID file though
# (Note in real life two znapzends not given paths to work on
# would discover same datasets and policies and conflict while
# sending/receiving stuff)
eval {
    $Test->is_num (1, runCommand_canThrow(qw(--daemonize --debug),'--features=compressed',
        qw(--pidfile=znapzend2.pid)), 'Daemons be here: znapzend --daemonize #2');
};

# ASSUMPTION: Eval and time should cover up the users for that pidfile
# For coverage, test also the daemon mode doing nothing R/W wise
eval {
    $Test->is_num (1, runCommand_canThrow(qw(--daemonize),'-n',
        qw(--pidfile=znapzend.pid)), 'Daemons be here: znapzend --daemonize #3');
};

# Presumably also covers Test::More done_testing()... at least conflicts with it ;)
$Test->done_testing;
eval { done_testing(); };

1;
