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

use Test::More tests => 10;

use_ok 'ZnapZend::ZFS';
use_ok 'ZnapZend::Time';

my $zZFS  = ZnapZend::ZFS->new();
my $zTime = ZnapZend::Time->new();

is (ref $zZFS,'ZnapZend::ZFS', 'instantiation of ZFS');

is (ref $zTime, 'ZnapZend::Time', 'instantiation of Time');

isnt ($zZFS->listPools(), '', 'list pools');

my $zpoolStatus = $zZFS->zpoolStatus('tank');
isnt ($zpoolStatus, '', 'zpool status');

is ($zZFS->startScrub('tank'), 1, 'start scrub');

is ($zZFS->stopScrub('tank'), 1, 'stop scrub');

is ($zZFS->scrubActive('tank'), 0, 'scrub active');

isnt ($zTime->getLastScrubTimestamp($zpoolStatus), 0, 'last scrub time');
    
 
1;

