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

    main();
}

use Test::More;
use Test::Exception;

use_ok 'ZnapZend';

#load program
@ARGV = qw(--help);
do 'znapzend' or die "ERROR: loading program znapzend\n";

is (runCommand('--help'), 1, 'znapzend help');

is (runCommand(), 1, 'znapzend');

throws_ok { runCommand(qw(--runonce=nosets) ) } qr/No backup set defined or enabled/,
      'znapzend dies with no backup sets defined or enabled at startup';

# seems to allow tests to continue so why not?
is (runCommand('--help'), 1, 'znapzend help');

is (runCommand(qw(--daemonize --debug),'--features=oracleMode,recvu',
    qw( --pidfile=znapzend.pid)), 1, 'znapzend --daemonize');

done_testing;

1;
