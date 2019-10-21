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

$ENV{'ZNAPZENDTEST_ZFS_GET_ZEND_DELAY'} = '1';
is (runCommand(qw(--runonce=tank/source)), 1, 'znapzend --runonce=tank/source with zend-delay==1');
undef $ENV{'ZNAPZENDTEST_ZFS_GET_ZEND_DELAY'};

# Try an invalid string, should ignore and proceed without a delay
$ENV{'ZNAPZENDTEST_ZFS_GET_ZEND_DELAY'} = ' qwe ';
# TODO : Find a way to check stderr for qr/Option 'zend-delay' has an invalid value/
is (runCommand(qw(--runonce=tank/source)),
    1, 'znapzend --runonce=tank/source with zend-delay==" qwe " complains but survives');
undef $ENV{'ZNAPZENDTEST_ZFS_GET_ZEND_DELAY'};

# seems to allow tests to continue so why not?
is (runCommand('--help'), 1, 'znapzend help');

# Coverage for various failure codepaths
$ENV{'ZNAPZENDTEST_ZFS_GET_DST0PRECMD_FAIL'} = '1';
is (runCommand(qw(--runonce=tank/source)), 1, 'znapzend sendRecvCleanup with a failed DST PRE command');
$ENV{'ZNAPZENDTEST_ZFS_GET_DST0PRECMD_FAIL'} = undef;

$ENV{'ZNAPZENDTEST_ZFS_GET_DST0PSTCMD_FAIL'} = '1';
is (runCommand(qw(--runonce=tank/source)), 1, 'znapzend sendRecvCleanup with a failed DST POST command');
$ENV{'ZNAPZENDTEST_ZFS_GET_DST0PSTCMD_FAIL'} = undef;

$ENV{'ZNAPZENDTEST_ZFS_FAIL_send'} = '1';
is (runCommand(qw(--runonce=tank/source)), 1, 'znapzend sendRecvCleanup with a failed ZFS SEND command');
$ENV{'ZNAPZENDTEST_ZFS_FAIL_send'} = undef;

$ENV{'ZNAPZENDTEST_ZFS_FAIL_recv'} = '1';
is (runCommand(qw(--runonce=tank/source)), 1, 'znapzend sendRecvCleanup with a failed ZFS RECV command');
$ENV{'ZNAPZENDTEST_ZFS_FAIL_recv'} = undef;

$ENV{'ZNAPZENDTEST_ZFS_FAIL_destroy'} = '1';
is (runCommand(qw(--runonce=tank/source)), 1, 'znapzend sendRecvCleanup with a failed ZFS DESTROY command');
$ENV{'ZNAPZENDTEST_ZFS_FAIL_destroy'} = undef;


# Do not test after daemonize, to avoid conflicts
is (runCommand(qw(--daemonize --debug),'--features=oracleMode,recvu',
    qw(--pidfile=znapzend.pid)), 1, 'znapzend --daemonize #1');
#...but do try to cover these error codepaths ;)
eval { is (runCommand(qw(--daemonize --debug),'--features=Lce',
    qw(--pidfile=znapzend2.pid)), 1, 'znapzend --daemonize #2'); };
eval { is (runCommand(qw(--daemonize --debug),'-n',
    qw(--pidfile=znapzend.pid)), 1, 'znapzend --daemonize #3'); };

done_testing;

1;
