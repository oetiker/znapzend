#!/usr/bin/env perl

use strict;
use warnings;

use FindBin;
$ENV{PATH} = "$FindBin::Bin:$ENV{PATH}";
my $buildDir;

sub truncateLogFiles {
    open my $ffh, '>', 'file.log';
    close $ffh;

    open my $mfh, '>', 'mail.log';
    close $mfh;
}

BEGIN {
    $buildDir = shift @ARGV // "$FindBin::Bin/../";
    truncateLogFiles();
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

sub logContainsWarn {
    open my $fh, '<', shift;
    return ((grep /WARN/, <$fh>) != 0);
}

use Test::More;

use_ok 'ZnapZend';

#load program
@ARGV = qw(--help);
do 'znapzend' or die "ERROR: loading program znapzend\n";

is (runCommand('--help'), 1, 'znapzend help');

is (runCommand(), 1, 'znapzend');

is (runCommand(qw(--runonce=tank/source)), 1, 'znapzend --runonce');

is (runCommand('--logto=file::./file.log',
    '--logto=pipe::./mail -s "1st" a@a.com',
    '--logto=pipe::./mail -s "2nd" b@b.com'),
    1, 'znapzend logto file and pipes');
is (logContainsWarn('file.log'), 1, 'znapzend file log contains warn');
is (logContainsWarn('mail.log'), 1, 'znapzend pipe log contains warn');

is (runCommand(qw(--daemonize --debug),'--features=oracleMode,recvu',
    qw( --pidfile=znapzend.pid)), 1, 'znapzend --daemonize');

done_testing;
 
1;

