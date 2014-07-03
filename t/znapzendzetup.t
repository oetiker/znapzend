#!/usr/bin/env perl

use strict;
use warnings;

use FindBin;
$ENV{PATH} = "$FindBin::Bin:$ENV{PATH}";
my $binDir;

BEGIN {
    $binDir = shift @ARGV;
    $binDir //= "$FindBin::Bin/../bin";
}

#set testing switch
$ENV{ZNAPZEND_TESTING} = 1;

# PERL5LIB
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../thirdparty/lib/perl5";

unshift @INC, sub {
    my (undef, $filename) = @_;
    return () if $filename !~ /ZnapZend/;
    if (my $found = (grep { -e $_ } map { "$_/$filename" } grep { !ref } @INC)[0] ) {
        local $/ = undef;
        open my $fh, '<', $found or die("Can't read module file $found\n");
        my $module_text = <$fh>;
        close $fh;

        # define everything in a sub, so Devel::Cover will DTRT
        # NB this introduces no extra linefeeds so D::C's line numbers
        # in reports match the file on disk
        $module_text =~ s/(.*?package\s+\S+)(.*)__END__/$1sub classWrapper {$2} classWrapper();/s;
                
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

    main($mainOpt);
}

use Test::More tests => 11;

use_ok 'ZnapZend';

#load program
@ARGV = qw(help);
do "$binDir/znapzendzetup" or die "ERROR: loading program znapzendzetup\n";

is (runCommand('help'), 1, 'znapzendzetup help');

is (runCommand('list'), 1, 'znapzendzetup list');

is (runCommand(qw(create SRC 1h=>10min tank/source), 
    qw(DST 1h=>10min backup/destination)), 1, 'znapzendzetup create');

is (runCommand(qw(edit SRC 1h=>10min tank/source), 
    qw(DST:0 1h=>10min backup/destination)), 1, 'znapzendzetup edit');

is (runCommand(qw(create --donotask --tsformat=%Y%m%d-%H%M%S SRC 1h=>10min tank/source),
    qw(DST 1h=>10min backup/destination)), 1, 'znapzendzetup create --donotask');

is (runCommand(qw(edit --donotask --tsformat=%Y%m%d-%H%M%S SRC 1h=>10min tank/source),
    qw(DST:0 1h=>10min backup/destination)), 1, 'znapzendzetup edit --donotask');

is (runCommand(qw(enable tank/source)), 1, 'znapzendzetup enable');

is (runCommand(qw(disable tank/source)), 1, 'znapzendzetup disable');

is (runCommand(qw(delete tank/source)), 1, 'znapzendzetup delete');

is (runCommand(qw(delete --dst=0 tank/source)), 1, 'znapzendzetup delete destination');

1;

