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

done_testing;

1;

