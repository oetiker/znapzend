#!/usr/bin/env perl

# Test library methods around [[user@]host:]dataset[@snap] splitting
# since there are many use-cases and combinations to take care of.
# We do so below by constructing "task" strings from components we
# know to be a dataset name and some defined (or not) remote spec
# and/or snapshot name, and deconstructing it back with the class
# method.
#
# Copyright (C) 2024 by Jim Klimov <jimklimov@gmail.com>

use strict;
use warnings;

# Avoid issues if we monkey-patch included sources in a wrong way
use warnings FATAL => 'recursion';

use FindBin;
$ENV{PATH} = $FindBin::RealBin.':'.$ENV{PATH};
my $buildDir;

BEGIN {
    $buildDir = shift @ARGV // $FindBin::RealBin."/../";
}

# PERL5LIB
use lib "$FindBin::RealBin/../lib";
use lib "$buildDir/thirdparty/lib/perl5";
#place bin path to lib so it is stored in @INC
use lib "$FindBin::RealBin/../bin";

unshift @INC, sub {
    my (undef, $filename) = @_;
    return () if $filename !~ /ZnapZend|ZFS|znapzend/;
    if (my $found = (grep { -e $_ } map { "$_/$filename" } grep { !ref } @INC)[0] ) {
        local $/ = undef;
        open my $fh, '<', $found or die("Can't read module file $found\n");
        my $module_text = <$fh>;
        close $fh;

        # define everything in a sub, so Devel::Cover will DTRT
        # NB this introduces no extra linefeeds so D::C's line numbers
        # in reports match the file on disk
        $module_text =~ s/(.*?package\s+\S+)(.*)__END__/$1sub classWrapper {$2} classWrapper();/s;

        # unhide private methods to avoid "Variable will not stay shared"
        # warnings that appear due to change of applicable scoping rules
        # Note: not '\s*' in the start of string, to avoid matching and
        # removing blank lines before the private sub definitions.
        $module_text =~ s/^[ \t]*my\s+(\S+\s*=\s*sub.*)$/our $1/gm;

        # For this test, also strip dollars from tested private method
        # names so we can actually call them from the test context.
        if($filename =~ /ZFS/) {
            $module_text =~ s/^1;$/### Quick drop-in\nsub splitDataSetSnapshot {return \$splitDataSetSnapshot->(\$_[1]);}\nsub splitHostDataSet {return \$splitHostDataSet->(\$_[1]);}\n\n1;\n/gm;
        }

        if(defined($ENV{DEBUG_ZNAPZEND_SELFTEST_REWRITE})) {
            open(my $fhp, '>', $found . '.selftest-rewritten') or warn "Could not open " . $found . '.selftest-rewritten';
            if ($fhp) { print $fhp $module_text ; close $fhp; }
        }

        # filehandle on the scalar
        open $fh, '<', \$module_text;

        # and put it into %INC too so that it looks like we loaded the code
        # from the file directly
        $INC{$filename} = $found;

        warn ("Imported '$found'");
        return $fh;
    }
    else {
        return ();
    }
};

sub stringify {
    my $s = shift;
    return $s if defined($s);
    return "<undef>";
}

sub printTaskReport {
    print STDERR "[D] task='" . stringify($_[0]) .
        "' => remote='" . stringify($_[1]) .
        "' dataSetPathAndSnap='" . stringify($_[2]) .
        "' => dataSet='" . stringify($_[3]) .
        "' snapshot='" . stringify($_[4]) . "'\n";
}

use Test::More;

use_ok 'ZnapZend::ZFS';

my $zZFS  = ZnapZend::ZFS->new();

is (ref $zZFS,'ZnapZend::ZFS', 'instantiation of ZFS');

for my $r (qw(undef hostname username@hostname)) {
    for my $d (qw(poolrootfs rpool/dataset rpool/dataset:with-colon)) {
        for my $s (qw(undef snapname snap-1 snap-2:3 snap-12:35:00)) {
            #EXAMPLE# my $task = 'user@host:dataset@snapname';

            my $task = '';
            if ($r ne "undef") { $task .= $r . ':'; }
            $task .= $d;
            if ($s ne "undef") { $task .= '@' . $s; }

            # Decode it back, see if we can
            # Note the methods are externalized from the module for the test by patcher above
            my ($remote, $dataSetPathAndSnap) = $zZFS->splitHostDataSet($task);
            my ($dataSet, $snapshot) = $zZFS->splitDataSetSnapshot($dataSetPathAndSnap);
            #print STDERR "[D] task='$task' => remote='$remote' dataSetPathAndSnap='$dataSetPathAndSnap' => dataSet='$dataSet' snapshot='$snapshot'\n";
            printTaskReport($task, $remote, $dataSetPathAndSnap, $dataSet, $snapshot);

            is (defined ($dataSet), 1, "dataSet should always be defined after parsing");
            is (($dataSet eq $d), 1, "dataSet has expected value after parsing");

            if ($r ne "undef") {
                is (defined ($remote), 1, "remote should be defined after parsing this test case");
                is (($remote eq $r), 1, "remote has expected value after parsing");
            } else {
                isnt (defined ($remote), 1, "remote should not be defined after parsing this test case");
            }

            if ($s ne "undef") {
                is (defined ($snapshot), 1, "snapshot should be defined after parsing this test case");
                is (($snapshot eq $s), 1, "snapshot has expected value after parsing");
            } else {
                isnt (defined ($snapshot), 1, "snapshot should not be defined after parsing this test case");
            }
        }
    }
}

done_testing;

1;
