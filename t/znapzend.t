#!/usr/bin/env perl

use strict;
use warnings;

use FindBin;
$ENV{PATH} = "$FindBin::Bin:$ENV{PATH}";
my $buildDir;

BEGIN {
    $buildDir = shift @ARGV;
    $buildDir //= "$FindBin::Bin/../";
}

#set testing switch
$ENV{ZNAPZEND_TESTING} = 1;

# PERL5LIB
use lib "$FindBin::Bin/../lib";
use lib "$buildDir/thirdparty/lib/perl5";

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
    @ARGV = @_;

    main();
}

use Test::More tests => 4;

use_ok 'ZnapZend';

#load program
@ARGV = qw(--help);
do "$FindBin::Bin/../bin/znapzend" or die "ERROR: loading program znapzend\n";

is (runCommand('--help'), 1, 'znapzend help');

is (runCommand(), 1, 'znapzend');

is (runCommand(qw(--daemonize --debug --pidfile=znapzend.pid)), 1, 'znapzend --daemonize');
 
1;

