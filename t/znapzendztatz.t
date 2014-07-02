#!/usr/bin/env perl

use strict;
use warnings;

use FindBin;
$ENV{PATH} .= ":$FindBin::Bin";
my $binDir;

BEGIN {
    $binDir = shift @ARGV;
    $binDir //= "$FindBin::Bin/../bin";
}

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

use Test::More tests => 3;

use_ok 'ZnapZend';

#load program
@ARGV = qw(--help);
do "$binDir/znapzendztatz" or die "ERROR: loading program znapzendztatz\n";

is (runCommand('--help'), 1, 'znapzendztatz help');
 
is (runCommand(), 1, 'znapzendztatz');

1;

