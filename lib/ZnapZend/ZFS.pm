package ZnapZend::ZFS;

use Mojo::Base -base;

local $ENV{PATH} = "/usr/sbin:/usr/bin";

### attributes ###
has debug => sub { 0 };
has noaction => sub { 0 };
has nodestroy => sub { 1 };
has propertyPrefix => sub { 'org.znapzend' };
has sshCmdArray => sub { [qw(ssh -o Compression=yes -o CompressionLevel=1 -o Cipher=arcfour -o batchmode=yes)] };
#has sshCmdStr => sub { join ' ', @{shift->sshCmdArray} }; 
has snapshotFilter => sub { qr/\d{4}-\d{2}-\d{2}-\d{6}/ };
has mbufferParam => sub { [qw(-s 128k -m 1G -q)] };
has scrubInProgress => sub { qr/scrub in progress/ };

### private functions ###
my $splitHostDataSet = sub { return ($_[0] =~ /^(?:([^:]+):)?([^:]+)$/); };
my $splitDataSetSnapshot = sub { return ($_[0] =~ /^([^\@]+)\@([^\@]+)$/); };

my $shellQuote = sub {
    my @return;
    for my $group (@_){
        my @args = @$group;
        for (@args){
            s/'/'"'"'/g;
        }
        push @return, join ' ', map {/^[-=_0-9a-z]+$/i ? $_ : qq{'$_'}} @args;
    }
    return join '|', @return;
};

my $buildRemoteRefArray = sub {
    my $self = shift;
    my $remote = shift;
    if ($remote){
        return [@{$self->sshCmdArray}, $remote, $shellQuote->(@_)];
    }
    return @_;
};

my $buildRemote = sub {
    my $self = shift;
    my @list = $self->$buildRemoteRefArray(@_);
    return @{$list[0]};
};


my $sendRecvSnapshots = sub {
    my $self = shift;
    my $exec = shift;
    my $srcDataSet = shift;
    my $dstDataSet = shift;
    my $mbuffer = shift;
    my $remote;
    my ($lastSnapshot, $lastCommon) = $self->lastAndCommonSnapshots($srcDataSet, $dstDataSet);

    return 1 if !$lastSnapshot or (defined $lastCommon and ($lastSnapshot eq $lastCommon));

    ($remote, $dstDataSet) = $splitHostDataSet->($dstDataSet);

    my @cmd;
    if ($lastCommon){
        @cmd = (['zfs', 'send', '-I', $lastCommon, $lastSnapshot]);
    }
    else{
        @cmd = (['zfs', 'send', $lastSnapshot]);
    }

    my @mbCmd = $mbuffer ne 'off' ? ([$mbuffer, @{$self->mbufferParam}]) : () ;
    my $recvCmd = ['zfs', 'recv' , '-F', $dstDataSet];

    push @cmd,  $self->$buildRemoteRefArray($remote, @mbCmd, $recvCmd);

    my $cmd = $shellQuote->(@cmd);
    print STDERR "# $cmd\n" if $self->debug; 

    if (not $self->noaction){
        $exec ? exec($cmd) : system($cmd);
        die "ERROR: cannot send snapshot to $remote ($?)\n" if $?;
    }
    return 1;
};

my $scrubZpool = sub {
    my $self = shift;
    my $startstop = shift;
    my $zpool = shift;
    
    my ($remote, $pool) = $splitHostDataSet->($zpool);
    my @cmd = $startstop ? qw(zpool scrub) : qw(zpool scrub -s);

    my @ssh = $self->$buildRemote($remote, [@cmd, $pool]);
    print STDERR '# ' . join(' ', @ssh) . "\n" if $self->debug;
    (system(@ssh) and die 'ERROR: could not ' . ($startstop ? 'start' : 'stop') .  " scrub on $pool") if not $self->noaction;
    return 1;
};

my $zpoolStatus = sub {
    my $self = shift;
    my $english = shift;
    my $zpool = shift;

    my ($remote, $pool) = $splitHostDataSet->($zpool);

    my @cmd = $english ? qw(env LC_MESSAGES=C LC_DATE=C zpool status -v) : qw(zpool status -v);
    my @ssh = $self->$buildRemote($remote, [@cmd, $pool]);

    print STDERR '# ' . join(' ', @ssh) . "\n" if $self->debug;
    open (my $zpoolStatus, '-|', @ssh) or die "ERROR: cannot get status of $pool\n";

    my @status = <$zpoolStatus>;
    chomp(@status);

    return \@status;
};

### public methods ###
sub dataSetExists {
    my $self = shift;
    my $dataSet = shift;
    my $remote;
   
    #just in case if someone aks to check '';
    return 0 if not $dataSet;

    ($remote, $dataSet) = $splitHostDataSet->($dataSet);
    return grep { $dataSet eq $_ } @{$self->listDataSets($remote)};
}

sub listDataSets {
    my $self = shift;
    my $remote = shift;

    my @ssh = $self->$buildRemote($remote, [qw(zfs list -H -o name)]);

    print STDERR '# ' . join(' ', @ssh) . "\n" if $self->debug;
    open (my $dataSets, '-|', @ssh) or die 'ERROR: cannot get datasets' . ($remote ? " on $remote\n" : "\n");
    my @dataSets = <$dataSets>;
    chomp(@dataSets);

    return \@dataSets;
}

sub listSnapshots {
    my $self = shift;
    my $dataSet = shift;
    my $remote;
    my $snapshotFilter = $self->snapshotFilter;
    my @snapshots;

    ($remote, $dataSet) = $splitHostDataSet->($dataSet);
    my @ssh = $self->$buildRemote($remote,[qw(zfs list -t snapshot -o name -s name -r -d 1), $dataSet]);

    print STDERR '# ' . join(' ', @ssh) . "\n" if $self->debug;
    open (my $snapshots, '-|', @ssh) or die "ERROR: cannot get snapshots on $dataSet\n";

    while (<$snapshots>){
        chomp;
        next if not /^(\Q$dataSet\E\@$snapshotFilter)$/;
        push @snapshots, $_;
    }

    @snapshots = map { ($remote ? "$remote:" : '') . $_ } @snapshots;
    return \@snapshots;
}

sub listSubDataSets {
    my $self = shift;
    my $dataSet = shift;
    my $remote;
    my @dataSets;

    ($remote, $dataSet) = $splitHostDataSet->($dataSet);
    my @ssh = $self->$buildRemote($remote, [qw(zfs list -H -r -o name), $dataSet]);

    print STDERR '# ' . join(' ', @ssh) . "\n" if $self->debug;
    open (my $dataSets, '-|', @ssh) or die "ERROR: cannot get sub datasets on $dataSet\n";

    while (<$dataSets>){
        chomp;
        next if not /^\Q$dataSet\E/;
        push @dataSets, $_;
    }

    @dataSets = map { ($remote ? "$remote:" : '') . $_ } @dataSets;
    return \@dataSets;
}

sub createSnapshot {
    my $self = shift;
    my $dataSet = shift;
    my $remote;
    my $recursive = $_[0] ? '-r' : '';

    ($remote, $dataSet) = $splitHostDataSet->($dataSet);
    my @ssh = $self->$buildRemote($remote, [qw(zfs snapshot), $recursive, $dataSet]);

    print STDERR '# ' .  join(' ', @ssh) . "\n" if $self->debug;
    (system(@ssh) and die "ERROR: cannot create snapshot $dataSet\n") if not $self->noaction;

    return 1;
}

# known limitation: snapshots from subdatasets have to be destroyed individually
sub destroySnapshots {
    my $self = shift;
    my @toDestroy = ref($_[0]) eq "ARRAY" ? @{$_[0]} : ($_[0]);
    my %toDestroy;
    my ($remote, $dataSet, $snapshot);

    for (@toDestroy){
        ($remote, $dataSet) = $splitHostDataSet->($_);
        ($dataSet, $snapshot) = $splitDataSetSnapshot->($dataSet);
        #tag local snapshots as 'local' so we have a key to build the hash
        $remote = $remote || 'local';
        $toDestroy{$remote} = [] if not exists $toDestroy{$remote};
        push @{$toDestroy{$remote}}, @{$toDestroy{$remote}} ? $snapshot : "$dataSet\@$snapshot";
    }

    for $remote (keys %toDestroy){
        #check if remote is flaged as 'local'.
        my @ssh = $self->$buildRemote($remote ne 'local' ? $remote : undef, [qw(zfs destroy), join(',', @{$toDestroy{$remote}})]);

        print STDERR '# ' . join(' ', @ssh) . "\n" if $self->debug;
        (system(@ssh) and die "ERROR: cannot destroy snapshot(s) $toDestroy[0]\n") if not ($self->noaction || $self->nodestroy);
    }
    return 1;
}

sub lastAndCommonSnapshots {
    my $self = shift;
    my $srcDataSet = shift;
    my $dstDataSet = shift;
    my $snapshotFilter = $self->snapshotFilter;

    my $srcSnapshots = $self->listSnapshots($srcDataSet);
    my $dstSnapshots = $self->listSnapshots($dstDataSet);

    return (undef, undef) if not @{$srcSnapshots};

    my ($i, $snapTime);
    for ($i = $#{$srcSnapshots}; $i >= 0; $i--){
        ($snapTime) = ${$srcSnapshots}[$i] =~ /^\Q$srcDataSet\E\@($snapshotFilter)/;

        last if grep { /$snapTime/ } @{$dstSnapshots};
    }
    return (${$srcSnapshots}[-1], (grep { /$snapTime/ } @{$dstSnapshots}) ? ${$srcSnapshots}[$i] : undef);
}

sub sendRecvSnapshots {
    my $self = shift;
    return $self->$sendRecvSnapshots(0, @_);
}

sub sendRecvSnapshotsExec {
    my $self = shift;
    return $self->$sendRecvSnapshots(1, @_);;
}

sub getDataSetProperties {
    my $self = shift;
    my $dataSet = shift;
    my @propertyList;
    my $propertyPrefix = $self->propertyPrefix;

    my $list = $dataSet ? [ ($dataSet) ] : $self->listDataSets();
    
    for my $listElem (@{$list}){
        my %properties;
        my @cmd = (qw(zfs get -H -s local -o), 'property,value', 'all', $listElem);
        print STDERR '# ' . join(' ', @cmd) . "\n" if $self->debug;
        open (my $props, '-|', @cmd) or die "ERROR: could not get zfs properties\n";
        while (<$props>){
            chomp;
            my ($key, $value) = /^\Q$propertyPrefix\E:(\S+)\t(.+)$/ or next;
            $properties{$key} = $value;
        }
        if (%properties){
        # place source dataset on list, too. so we know where the properties are from...
            $properties{src} = $listElem;
            push @propertyList, \%properties;
        }
    }
    return \@propertyList;
}

sub setDataSetProperties {
    my $self = shift;
    my $dataSet = shift;
    my $properties = shift;
    my $propertyPrefix = $self->propertyPrefix;

    return 0 if not $self->dataSetExists($dataSet);

    for my $prop (keys %{$properties}){
        my @cmd = (qw(zfs set), "$propertyPrefix:$prop=$properties->{$prop}", $dataSet);
        print STDERR '# ' . join(' ', @cmd) . "\n" if $self->debug;
        (system(@cmd) and die "ERROR: could not set property $prop on $dataSet\n") if not $self->noaction;
    }
    return 1;
}

sub deleteDataSetProperties {
    my $self = shift;
    my $dataSet = shift;
    my $propertyPrefix = $self->propertyPrefix;

    return 0 if not $self->dataSetExists($dataSet);
    my $properties = $self->getDataSetProperties($dataSet);

    return 0 if not @{$properties}[0];

    for my $prop (keys @{$properties}[0]){
        my @cmd = (qw(zfs inherit), "$propertyPrefix:$prop", $dataSet);
        print STDERR '# ' . join(' ', @cmd) . "\n" if $self->debug;
        (system(@cmd) and die "ERROR: could not reset property $prop on $dataSet\n") if not $self->noaction;
    }
    return 1;
}

sub deleteBackupDestination {
    my $self = shift;
    my $dataSet = shift;
    my $dst = $self->propertyPrefix . ':' . $_[0];

    return 0 if not $self->dataSetExists($dataSet);
    
    my @cmd = (qw(zfs inherit), $dst, $dataSet);
    print STDERR '# ' . join(' ', @cmd) . "\n" if $self->debug;
    (system(@cmd) and die "ERROR: could not reset property on $dataSet\n") if not $self->noaction;
    @cmd = (qw(zfs inherit), $dst . '_plan', $dataSet);
    print STDERR '# ' . join(' ', @cmd) . "\n" if $self->debug;
    (system(@cmd) and die "ERROR: could not reset property on $dataSet\n") if not $self->noaction;
    return 1;
}

sub fileExistsAndExec {
    my $self = shift;
    my $filePath = shift;

    my ($remote, $file) = $splitHostDataSet->($filePath);
    
    my @ssh = $self->$buildRemote($remote, [qw(test -x), $file]);

    print STDERR '# ' . join(' ', @ssh) . "\n" if $self->debug;
    return not system(@ssh);
}

sub listPools {
    my $self = shift;
    my $remote = shift;

    my @ssh = $self->$buildRemote($remote, [qw(zpool list -H -o name)]);

    print STDERR '# ' . join(' ', @ssh) . "\n" if $self->debug;
    open (my $zPools, '-|', @ssh) or die 'ERROR: cannot get zpools' . ($remote ? " on $remote\n" : "\n");
    my @zPools = <$zPools>;
    chomp(@zPools);

    return \@zPools;
}

sub startScrub {
    my $self = shift;
    #zpool is second argument

    return $self->$scrubZpool(1, @_);
}

sub stopScrub {
    my $self = shift;
    #zpool is second argument

    return $self->$scrubZpool(0, @_);
}

sub zpoolStatus {
    my $self = shift;
    #zpool is second argument

    return $self->$zpoolStatus(0, @_);
}

sub zpoolStatusEN {
    my $self = shift;
    #zpool is second argument

    return $self->$zpoolStatus(1, @_);
}

sub scrubActive {
    my $self = shift;
    #zpool is second argument
     
    my $scrubProgress = $self->scrubInProgress;

    return grep { /$scrubProgress/ } @{$self->$zpoolStatus(1, @_)};
}

1;

__END__

=head1 NAME

ZnapZend::ZFS - zfs control object

=head1 SYNOPSIS

use ZnapZend::ZFS;
...
my $zfs = ZnapZend::ZFS->new(debug=>0, noaction=>0);
...

=head1 DESCRIPTION

this object makes zfs snapshot functionality easier to use

=head1 ATTRIBUTES

=head2 debug

print debug information to STDERR

=head2 noaction

do a dry run. no changes to the filesystem will be performed

=head2 nodestroy

runs does all changes to the filesystem *except* destroy

=head1 METHODS

=head2 dataSetExists

checks if the dataset exists on localhost or a remote host

=head2 listDataSets

lists datasets on (remote-)host

=head2 listSnapshots

returns a list of all snapshots of the dataset

=head2 listSubDataSets

returns a list of all subdataset including the dataset itself

=head2 createSnapshot

chreates a snapshot on localhost or a remote host

=head2 destroySnapshots

destroys a single snapshot or a list of snapshots on localhost or a remote host

=head2 lastAndCommonSnapshots

lists the last snapshot on source and the last common snapshot an source and destination

=head2 sendRecvSnapshots

sends snapshots to a different destination on localhost or a remote host

=head2 sendRecvSnapshotsExec

same as sendRecvSnapshots but calls 'exec'

=head2 getDataSetProperties

gets dataset properties

=head2 setDataSetProperties

sets dataset properties

=head2 deleteDataSetProperties

deletes dataset properties

=head2 deleteBackupDestination

remove a backup destination from a backup plan

=head2 fileExistsAndExec

checks if a file exists and has the executable flag set on localhost or a remote host

=head2 listPools

lists zpools on localhost or a remote host

=head2 startScrub

stats scrub on a zpool

=head2 stopScrub

stops scrub on a zpool

=head2 zpoolStatus

returns status info of a zpool

=head2 zpoolStatusEN

regurns status info of a zpool in englisch

=head2 scrubActive

returns whether scrub is active on zpool or not

=head1 COPYRIGHT

Copyright (c) 2014 by OETIKER+PARTNER AG. All rights reserved.

=head1 LICENSE

This program is free software: you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option)
any later version.

This program is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
more details.

You should have received a copy of the GNU General Public License along with
this program. If not, see L<http://www.gnu.org/licenses/>.

=head1 AUTHOR

S<Tobias Oetiker E<lt>tobi@oetiker.chE<gt>>
S<Dominik Hassler>

=head1 HISTORY

2014-06-02 had zpool functionality added
2014-06-01 had Multi destination backup
2014-05-30 had Initial Version

=cut
