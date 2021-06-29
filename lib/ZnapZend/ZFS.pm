package ZnapZend::ZFS;

use Mojo::Base -base;
use Mojo::Exception;
use Mojo::IOLoop::ForkCall;
use Data::Dumper;
use inheritLevels;

### attributes ###
has debug           => sub { 0 };
has noaction        => sub { 0 };
has nodestroy       => sub { 1 };
has oracleMode      => sub { 0 };
has recvu           => sub { 0 };
has resume          => sub { 0 };
has compressed      => sub { 0 };
has sendRaw         => sub { 0 };
has skipIntermediates => sub { 0 };
has forbidDestRollback => sub { 0 };
has lowmemRecurse   => sub { 0 };
has zfsGetType      => sub { 0 };
has rootExec        => sub { q{} };
has sendDelay       => sub { 3 };
has connectTimeout  => sub { 30 };
has propertyPrefix  => sub { q{org.znapzend} };
has sshCmdArray     => sub { [qw(ssh),
    qw(-o batchMode=yes -o), 'ConnectTimeout=' . shift->connectTimeout] };
has mbufferParam    => sub { [qw(-q -s 256k -W 600 -m)] }; #don't remove the -m as the buffer size will be added
has scrubInProgress => sub { qr/scrub in progress/ };

has zLog            => sub {
    my $stack = "";
    for (my $i = 0; my @r = caller($i); $i++) { $stack .= "$r[1]:$r[2] $r[3]\n"; }
    Mojo::Exception->throw('ZFS::zLog must be specified at creation time!' . "\n$stack");
};
has priv            => sub { my $self = shift; [$self->rootExec ? split(/ /, $self->rootExec) : ()] };

### private functions ###
my $splitHostDataSet = sub {
    return ($_[0] =~ /^(?:([^:\/]+):)?([^:]+|[^:@]+\@.+)$/);
};

my $splitDataSetSnapshot = sub {
    return ($_[0] =~ /^([^\@]+)\@([^\@]+)$/);
};

my $shellQuote = sub {
    my @return;

    for my $group (@_){
        my @args = @$group;
        for (@args){
            s/'/'"'"'/g;
        }
        push @return, join ' ', map {/^[-\/@=_0-9a-z]+$/i ? $_ : qq{'$_'}} @args;
    }

    return join '|', @return;
};

### private methods ###
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

my $scrubZpool = sub {
    my $self = shift;
    my $startstop = shift;
    my $zpool = shift;
    my $remote;

    ($remote, $zpool) = $splitHostDataSet->($zpool);
    my @cmd = (@{$self->priv}, ($startstop ? qw(zpool scrub) : qw(zpool scrub -s)));

    my @ssh = $self->$buildRemote($remote, [@cmd, $zpool]);
    print STDERR '# ' . ($self->noaction ? "WOULD # " : "" ) . join(' ', @ssh) . "\n" if $self->debug;
    system(@ssh) && Mojo::Exception->throw('ERROR: cannot '
        . ($startstop ? 'start' : 'stop') . " scrub on $zpool") if !$self->noaction;

    return 1;
};

### public methods ###
sub dataSetExists {
    # Note: Despite the "dataset" in the name, this routine only asks about
    # the "live datasets" (filesystem,volume) and not snapshots which are
    # also a type of dataset in ZFS terminology. See snapshotExists() below.
    my $self = shift;
    my $dataSet = shift;
    my $remote;

    #just in case if someone asks to check '';
    return 0 if !$dataSet;

    ($remote, $dataSet) = $splitHostDataSet->($dataSet);
    my @ssh = $self->$buildRemote($remote, [@{$self->priv}, qw(zfs list -H -o name -t), 'filesystem,volume', $dataSet]);

    print STDERR '# ' . join(' ', @ssh) . "\n" if $self->debug;
    open my $dataSets, '-|', @ssh
        or Mojo::Exception->throw('ERROR: cannot get datasets'
            . ($remote ? " on $remote" : ''));

    my @dataSets = <$dataSets>;
    chomp(@dataSets);

    return grep { $dataSet eq $_ } @dataSets;
}

sub snapshotExists {
    my $self = shift;
    # Note: this is a fully qualified name of dataset@snapshot ZFS object,
    # not just the snapname. May also be with remote destination ID.
    my $snapshot = shift;
    my $quiet = shift; # Maybe we expect it to not be there?
    if (!defined($quiet)) { $quiet = 0; }
    my $quietStr = ( $quiet ? '2>/dev/null' : '');

    my $remote;

    #just in case if someone asks to check '';
    return 0 if !$snapshot;

    ($remote, $snapshot) = $splitHostDataSet->($snapshot);
    my @ssh = $self->$buildRemote($remote,
        [@{$self->priv}, qw(zfs list -H -o name -t snapshot), $snapshot]);

    print STDERR '# ' . join(' ', @ssh, $quietStr) . "\n" if $self->debug;
    # FIXME : Find a way to really use $quietStr here safely... backticks?
    open my $snapshots, '-|', @ssh
        or Mojo::Exception->throw('ERROR: cannot get snapshots'
            . ($remote ? " on $remote" : ''));

    my @snapshots = <$snapshots>;
    chomp(@snapshots);

    return grep { $snapshot eq $_ } @snapshots;
}

sub listDataSets {
    # Note: Despite the "dataset" in the name, this routine only asks about
    # the "live datasets" (filesystem,volume) and not snapshots which are
    # also a type of dataset in ZFS terminology. See listSnapshots() below.
    my $self = shift;
    my $remote = shift;
    my $rootDataSets = shift; # May be not passed, or may be a string, or an array of strings
    my $recurse = shift; # May be not passed => undef

    my @ssh = $self->$buildRemote($remote, [@{$self->priv}, qw(zfs list -H -o name -t), 'filesystem,volume']);
    # By default this lists all fs/vol datasets in the system
    # Optionally we can ask for specific rootDataSets possibly with children
    if (defined ($rootDataSets) && $rootDataSets) {
        my @useRDS;
        if ( (ref($rootDataSets) eq 'ARRAY') ) {
            if (scalar(@$rootDataSets) > 0) {
                push (@useRDS, @$rootDataSets);
            }
        } else {
            # Assume string
            if ($rootDataSets ne "") {
                push (@useRDS, ($rootDataSets));
            }
        }
        if (scalar(@useRDS) > 0) {
            if (defined ($recurse) && $recurse) {
                push (@ssh, qw(-r));
            }
            push(@ssh, @useRDS);
        }
    }

    print STDERR '# ' . join(' ', @ssh) . "\n" if $self->debug;
    open my $dataSets, '-|', @ssh
        or Mojo::Exception->throw('ERROR: cannot get datasets'
            . ($remote ? " on $remote" : ''));

    my @dataSets = <$dataSets>;
    chomp(@dataSets);

    return \@dataSets;
}

sub listSnapshots {
    my $self = shift;
    my $dataSet = shift;
    my $snapshotFilter = shift // qr/.*/;
    my $lastSnapshotToSee = shift // undef; # Stop creation-ordered listing after registering this snapshot name - if there is one in the filtered selection
    if (defined($lastSnapshotToSee)) {
        if ($lastSnapshotToSee eq "") { $lastSnapshotToSee = undef; }
        else { $lastSnapshotToSee =~ s/^.*\@// ; }
    }
    my $remote;
    my @snapshots;

    ($remote, $dataSet) = $splitHostDataSet->($dataSet);
    my @ssh = $self->$buildRemote($remote,
        [@{$self->priv}, qw(zfs list -H -o name -t snapshot -s creation -d 1), $dataSet]);

    print STDERR '# ' . join(' ', @ssh) . "\n" if $self->debug;
    open my $snapshots, '-|', @ssh
        or Mojo::Exception->throw("ERROR: cannot get snapshots on $dataSet");

    while (my $snap = <$snapshots>){
        chomp $snap;
        if (defined($lastSnapshotToSee)) {
            if ($snap  =~ /^\Q$dataSet\E\@$lastSnapshotToSee$/) {
                # Only add this name to list if it matches $snapshotFilter ...
                push @snapshots, $snap if $snap =~ /^\Q$dataSet\E\@$snapshotFilter$/;
                # ...but still stop iterating
                $self->zLog->debug("listSnapshots() : for dataSet='$dataSet' snapshotFilter='$snapshotFilter' lastSnapshotToSee='$lastSnapshotToSee' matched '$snap' and stopping the iteration");
                last;
            }
        }
        next if $snap !~ /^\Q$dataSet\E\@$snapshotFilter$/;
        push @snapshots, $snap;
    }

    @snapshots = map { ($remote ? "$remote:" : '') . $_ } @snapshots;
    return \@snapshots;
}

sub extractSnapshotNames {
    # Routines like listSnapshots() operate with fully qualified
    # "dataset@snapname" strings as returned by ZFS. For some data
    # matching we need to compare just the "snapname" lists.
    my $self = shift;
    my $array = shift; # Note: call with extractSnapshotNames(\@arrVarName) !
    my @ret;
    if (ref($array) eq 'ARRAY') {
        if (scalar(@$array)) {
            for (@$array) {
                /\@(.+)$/ and push @ret, $1;
            }
        }
    } else {
#        return \@ret if (!$array);
#        eval { return \@ret if ($array == 1); };

        # String or unprocessed whitespace separated series?
        #print STDERR "=== extractSnapshotNames:\n\tGOT '" . ref($array) . "', will recurse: " . Dumper($array) if $self->debug;
        if ($array =~ m/\s+/) {
            my @tmp = split(/\s+/, $array);
            #print STDERR "=== extractSnapshotNames:\n\tTMP: " . Dumper(\@tmp) if $self->debug;
            return $self->extractSnapshotNames(\@tmp);
        }
        return $self->extractSnapshotNames( [$array] );
    }
    #print STDERR "=== extractSnapshotNames:\n\tGOT '" . ref($array) . "': " . Dumper($array) . "\tMADE: " . Dumper(\@ret) if $self->debug;
    return \@ret;
}

### Works:
# $self->zZfs->extractSnapshotNames( [ 'dsa@test1', 'dsa@test2', 'dsa@test3' ] );
# $self->zZfs->extractSnapshotNames('ds@test1 ds@test2
#   ds@test3');

### Does not work;
# $self->zZfs->extractSnapshotNames( qw(dsq@test1 dsq@test2 dsq@test3) );



sub createDataSet {
    my $self = shift;
    my $dataSet = shift;
    my $remote;

    #just in case if someone asks to check '';
    return 0 if !$dataSet;

    ($remote, $dataSet) = $splitHostDataSet->($dataSet);
    my @ssh = $self->$buildRemote($remote,
        [@{$self->priv}, qw(zfs create -p), $dataSet]);

    print STDERR '# ' . ($self->noaction ? "WOULD # " : "" ) . join(' ', @ssh) . "\n" if $self->debug;

    #return if 'noaction' or dataset creation successful
    return 1 if $self->noaction || !system(@ssh);

    #check if dataset already exists and therefore creation failed
    return 0 if $self->dataSetExists($dataSet);

    #creation failed and dataset does not exist, throw an exception
    Mojo::Exception->throw("ERROR: cannot create dataSet $dataSet");
}

sub listSubDataSets {
    my $self = shift;
    my $hostAndDataSet = shift;
    my @dataSets;

    my ($remote, $dataSet) = $splitHostDataSet->($hostAndDataSet);
    my @ssh = $self->$buildRemote($remote, [@{$self->priv}, qw(zfs list -H -r -o name -t), 'filesystem,volume', $dataSet]);

    print STDERR '# ' . join(' ', @ssh) . "\n" if $self->debug;
    open my $dataSets, '-|', @ssh
        or Mojo::Exception->throw("ERROR: cannot get sub datasets on $dataSet");

    while (my $task = <$dataSets>){
        chomp $task;
        next if $task !~ /^\Q$dataSet\E/;
        push @dataSets, $task;
    }

    my @subDataSets = map { ($remote ? "$remote:" : '') . $_ } @dataSets;

    return \@subDataSets;
}

sub createSnapshot {
    my $self = shift;
    my $hostAndDataSet = shift;
    my @recursive = $_[0] ? ('-r') : ();


    my ($remote, $dataSet) = $splitHostDataSet->($hostAndDataSet);
    my @ssh = $self->$buildRemote($remote, [@{$self->priv}, qw(zfs snapshot), @recursive, $dataSet]);

    print STDERR '# ' . ($self->noaction ? "WOULD # " : "" ) .  join(' ', @ssh) . "\n" if $self->debug;

    #return if 'noaction' or snapshot creation successful
    return 1 if $self->noaction || !system(@ssh);

    #check if snapshot already exists and therefore creation failed
    return 0 if $self->snapshotExists($dataSet);

    #creation failed and snapshot does not exist, throw an exception
    Mojo::Exception->throw("ERROR: cannot create snapshot $dataSet");
}

sub destroySnapshots {
    # known limitation: snapshots from subdatasets have to be
    # destroyed individually on some ZFS implementations
    my $self = shift;
    my @toDestroy = ref($_[0]) eq "ARRAY" ? @{$_[0]} : ($_[0]);
    my %toDestroy;
    my ($remote, $dataSet, $snapshot);
    my @recursive = $_[1] ? ('-r') : ();

    #oracleMode: destroy each snapshot individually
    if ($self->oracleMode){
        my $destroyError = '';
        for my $task (@toDestroy){
            my ($remote, $dataSetPathAndSnap) = $splitHostDataSet->($task);
            my ($dataSet, $snapshot) = $splitDataSetSnapshot->($dataSetPathAndSnap);
            my @ssh = $self->$buildRemote($remote, [@{$self->priv}, qw(zfs destroy), @recursive, "$dataSet\@$snapshot"]);

            print STDERR '# ' . (($self->noaction || $self->nodestroy) ? "WOULD # " : "") . join(' ', @ssh) . "\n" if $self->debug;
            system(@ssh) and $destroyError .= "ERROR: cannot destroy snapshot $dataSet\@$snapshot\n"
                if !($self->noaction || $self->nodestroy);
        }
        #remove trailing \n
        chomp $destroyError;
        Mojo::Exception->throw($destroyError) if $destroyError ne '';

        return 1;
    }

    #combinedDestroy
    for my $task (@toDestroy){
        my ($remote, $dataSetPathAndSnap) = $splitHostDataSet->($task);
        my ($dataSet, $snapshot) = $splitDataSetSnapshot->($dataSetPathAndSnap);
        #tag local snapshots as 'local' so we have a key to build the hash
        $remote = $remote || 'local';
        exists $toDestroy{$remote} or $toDestroy{$remote} = [];
        push @{$toDestroy{$remote}}, scalar @{$toDestroy{$remote}} ? $snapshot : "$dataSet\@$snapshot" ;
    }

    for $remote (keys %toDestroy){
        #check if remote is flaged as 'local'.
        my @ssh = $self->$buildRemote($remote ne 'local'
            ? $remote : undef, [@{$self->priv}, qw(zfs destroy), @recursive, join(',', @{$toDestroy{$remote}})]);

        print STDERR '# ' . (($self->noaction || $self->nodestroy) ? "WOULD # " : "")  . join(' ', @ssh) . "\n" if $self->debug;
        system(@ssh) && Mojo::Exception->throw("ERROR: cannot destroy snapshot(s) $toDestroy[0]")
            if !($self->noaction || $self->nodestroy);
    }

    return 1;
}

sub lastAndCommonSnapshots {
    my $self = shift;
    my $srcDataSet = shift;
    my $dstDataSet = shift;
    my $snapshotFilter = shift // qr/.*/;
    my $lastSnapshotToSee = shift // undef; # Stop creation-ordered listing after registering this snapshot name - if there is one in the filtered selection
    if (defined($lastSnapshotToSee)) {
        if ($lastSnapshotToSee eq "") { $lastSnapshotToSee = undef; }
        else { $lastSnapshotToSee =~ s/^.*\@// ; }
    }

    my $srcSnapshots = $self->listSnapshots($srcDataSet, $snapshotFilter, $lastSnapshotToSee);
    my $dstSnapshots = $self->listSnapshots($dstDataSet, $snapshotFilter, $lastSnapshotToSee);

    return (undef, undef, undef) if !scalar @$srcSnapshots;

    # For default operations, snapshot name is the time-based pattern
    my ($i, $snapName);
    for ($i = $#{$srcSnapshots}; $i >= 0; $i--){
        ($snapName) = ${$srcSnapshots}[$i] =~ /^\Q$srcDataSet\E\@($snapshotFilter)/;

        last if grep { /\@$snapName$/ } @$dstSnapshots;
    }

    ### print STDERR "LASTCOMMON: i=$i snapName=$snapName\nSRC: " . Dumper($srcSnapshots) . "DST: ". Dumper($dstSnapshots) . "LastToSee: " . Dumper($lastSnapshotToSee) if $self->debug;
    # returns: ($lastSrcSnapshotName, $lastCommonSnapshotName, $dstSnapCount)
    return (
        ${$srcSnapshots}[-1],
        ( ($i >= 0 && grep { /\@$snapName$/ } @$dstSnapshots) ? ${$srcSnapshots}[$i] : undef),
        scalar @$dstSnapshots
        );
}

sub mostRecentCommonSnapshot {
    # This is similar to lastAndCommonSnapshots() above, but considers not only
    # the "live" information from a currently accessible destination, but as a
    # fallback also the saved last-known-synced snapshot name.
    my $self = shift;
    my $srcDataSet = shift;
    my $dstDataSet = shift;
    my $dstName = shift; # name of the znapzend policy => property prefix
    my $snapshotFilter = shift;
    if (!defined($snapshotFilter) || !$snapshotFilter) {
        $snapshotFilter = qr/.*/;
    }

    # We can recurse from sendRecvCleanup() when looking for protected children
    # while preparing for a recursive cleanup of root backed-up source dataset.
    # NOTE that it is then up to zfs command to either return only data for the
    # snapshot named in the argument, or also same-named snapshots in children
    # of the dataset this is a snapshot of, so this flag may be effectively
    # ignored by OS.
    my $recurse = shift; # May be not passed => undef
    if (!defined($recurse)) {
        $recurse = 0;
    }

    # We do not have callers for the "inherit" argument at this time.
    # However we can have users replicating partial trees inheriting a policy.
    # Current call stack for sendRecvCleanup (primary user of this routine)
    # does not provide info whether this mode is used, so to be safer about
    # deletion of "protected" last-known-synced snapshots, we consider both
    # local and inherited values of the dst_X_synced flag, if present.
    # See definition of recognized $inherit values for this context in
    # getSnapshotProperties() code and struct inheritLevels.
    my $inherit = shift; # May be not passed => undef
    if (!defined($inherit)) {
        # We leave defined but invalid values of $inherit to
        # getSnapshotProperties() to figure out and complain,
        # but for this routine's purposes set a specific default.
        $inherit = new inheritLevels;
        $inherit->zfs_local(1);
        $inherit->zfs_inherit(1);
        $inherit->snapshot_recurse_parent(1);
    }

    my ($lastSnapshot, $lastCommonSnapshot, $dstSnapCount);
    ### DEBUG: Uncomment next line to enforce going through getSnapshotProperties() below
    #if(0)
    {
        local $@;
        eval {
            local $SIG{__DIE__};
            ($lastSnapshot, $lastCommonSnapshot, $dstSnapCount) = ($self->lastAndCommonSnapshots($srcDataSet, $dstDataSet, $snapshotFilter))[1];
        };
        if ($@){
            if (blessed $@ && $@->isa('Mojo::Exception')){
                $self->zLog->warn($@->message);
            }
            else{
                $self->zLog->warn($@);
            }
        }
    }

    if (not $lastCommonSnapshot){
        my $dstSyncedPropname = $dstName . '_synced';
        my @dstSyncedProps = [$dstSyncedPropname, $dstName];
        my $srcSnapshots = $self->listSnapshots($srcDataSet, $snapshotFilter);
        my $i;
        # Go from newest snapshot down in history and find the first one
        # to have a "non-false" value (e.g. "1") in its $dstName . '_synced'
        for ($i = $#{$srcSnapshots}; $i >= 0; $i--){
            my $snapshot = ${$srcSnapshots}[$i];
            my $properties = $self->getSnapshotProperties($snapshot, $recurse, $inherit, @dstSyncedProps);
            if ($properties->{$dstName} and ($properties->{$dstName} eq $dstDataSet) and $properties->{$dstSyncedPropname}){
                $lastCommonSnapshot = $snapshot;
                last;
            }
        }
    }
    return $lastCommonSnapshot;
}


sub sendRecvSnapshots {
    my $self = shift;
    my $srcDataSet = shift;
    my $dstDataSet = shift;
    my $dstName = shift; # name of the znapzend policy => property prefix
    my $mbuffer = shift;
    my $mbufferSize = shift;
    my $snapFilter = shift // qr/.*/;

    # Limit creation-ordered listing after registering this snapshot name,
    # (there may exist newer snapshots that would be not seen and replicated).
    # For practical purposes, this can be used with --since=X mode to ensure
    # that "X" exists on destination if it does not yet (note that if there
    # are newer snapshots on destination, they would be removed to allow
    # receiving "X", unless --forbidDestRollback is requested, in this case).
    my $lastSnapshotToSee = shift // undef; # Stop creation-ordered listing after registering this snapshot name - if there is one in the filtered selection
    if (defined($lastSnapshotToSee)) {
        if ($lastSnapshotToSee eq "") { $lastSnapshotToSee = undef; }
        else { $lastSnapshotToSee =~ s/^.*\@// ; }
    }

    # In certain cases, callers can set this argument to explicitly
    # forbid (0), allow (1) or enforce if needed (2) a rollback of dest.
    my $allowDestRollback = shift // undef;
    if (!defined($allowDestRollback)) { $allowDestRollback = (!$self->sendRaw && !$self->forbidDestRollback) ; }

    my @recvOpt = $self->recvu ? qw(-u) : ();
    push @recvOpt, '-F' if $allowDestRollback;
    my $incrOpt = $self->skipIntermediates ? '-i' : '-I';
    my @sendOpt = $self->compressed ? qw(-Lce) : ();
    push @sendOpt, '-w' if $self->sendRaw;
    push @recvOpt, '-s' if $self->resume;
    my $remote;
    my $mbufferPort;

    my $dstDataSetPath;
    ($remote, $dstDataSetPath) = $splitHostDataSet->($dstDataSet);

    # As seen through filter:
    # * Last existing snapshot on source,
    # * Last common snapshot between source and this destination,
    # * Overall count of snapshots on destination.
    my ($lastSnapshot, $lastCommon, $dstSnapCount)
        = $self->lastAndCommonSnapshots($srcDataSet, $dstDataSet, $snapFilter, $lastSnapshotToSee);

    if (defined($lastSnapshotToSee)) {
        $self->zLog->debug("sendRecvSnapshots() : " .
            "for srcDataSet='$srcDataSet' srcDataSet='$srcDataSet' " .
            "snapFilter='$snapFilter' lastSnapshotToSee='$lastSnapshotToSee' ".
            "GOT: lastSnapshot='$lastSnapshot' " .
            "lastCommon=" . ($lastCommon ? "'$lastCommon'" : "undef") . " " .
            "dstSnapCount='$dstSnapCount'"
            );
    }

    # We would set these source snapshot properties to mark that
    # this snapshot has been delivered to destination, to keep the
    # newest such snapshot if destination is unreachable currently.
    my %snapshotSynced = (
        $dstName,               $dstDataSet,
        $dstName . '_synced',   1
        );
    #nothing to do if no snapshot exists on source or if last common snapshot is last snapshot on source
    return 1 if !$lastSnapshot;
    if (defined $lastCommon && ($lastSnapshot eq $lastCommon)){
        $self->setSnapshotProperties($lastCommon, \%snapshotSynced);
        return 1;
    }

    #check if snapshots exist on destination if there is no common snapshot
    #as this will cause zfs send/recv to fail
    if (!$lastCommon and $dstSnapCount) {
        if ($allowDestRollback == 2) {
            # Asked to enforce if needed... is needed now
            $self->zLog->warn('WARNING: snapshot(s) exist on destination, but '
                . 'no common found on source and destination: was requested '
                . 'to clean up destination ' . $dstDataSet . ' (i.e. destroy '
                . 'existing snapshots that match the znapzend filter)');
            # TOTHINK: Maybe a "zfs rollback" to the oldest dst snapshot
            # and then removing it in one act is better for performance?
            # Can be destructive for man-named snapshots (if any) though...
            $self->destroySnapshots ($self->listSnapshots($dstDataSet, $snapFilter, undef));
            # If there are any manually created snapshots, with names not
            # matched by filter, `zfs recv -F` below would likely fail.
            # Still it is up to admins/users then to clean what they made,
            # we only mutilate automatically what we made automatically.

            # Reevaluate what is there now and look at all snapshots,
            # e.g. the manually named snapshots may be common to src
            # and dst, to have a starting point for such resync
            ($lastSnapshot, $lastCommon, $dstSnapCount)
                = $self->lastAndCommonSnapshots($srcDataSet, $dstDataSet, qr/.*/, $lastSnapshotToSee);
            my $dstSnapCountAll = scalar($self->listSnapshots($dstDataSet, qr/.*/, undef));
            # We do not throw/error here because snapshots may help sync
            $self->zLog->warn('ERROR: some snapshot(s) not covered '
                    . 'by znapzend filter still exist on destination: '
                    . 'this should be judged and fixed by the sysadmin '
                    . '(i.e. destroy manually named snapshots); '
                    . 'the zfs send+receive would likely fail below!'
                    ) if (!$lastCommon && $dstSnapCountAll>0);
        } else {
            Mojo::Exception->throw('ERROR: snapshot(s) exist on destination, but '
            . 'no common found on source and destination: clean up destination '
            . $dstDataSet . ' (i.e. destroy existing snapshots)');
        }
    }

    ($mbuffer, $mbufferPort) = split /:/, $mbuffer, 2;

    my @cmd;
    my @cmdSnaps;
    if ($lastCommon){
        @cmd = ([@{$self->priv}, 'zfs', 'send', @sendOpt, $incrOpt, $lastCommon, $lastSnapshot]);
	@cmdSnaps = ([$lastCommon, $lastSnapshot]);
    }
    else{
        @cmd = ([@{$self->priv}, 'zfs', 'send', @sendOpt, $lastSnapshot]);
	@cmdSnaps = ([$lastSnapshot]);
    }

    #if mbuffer port is set, run in 'network mode'
    if ($remote && $mbufferPort && $mbuffer ne 'off'){
        my $recvPid;

        my @recvCmd = $self->$buildRemoteRefArray($remote, [$mbuffer, @{$self->mbufferParam},
            $mbufferSize, '-4', '-I', $mbufferPort], [@{$self->priv}, 'zfs', 'recv', @recvOpt, $dstDataSetPath]);

        my $cmd = $shellQuote->(@recvCmd);

        my $fc = Mojo::IOLoop::ForkCall->new;
        $fc->run(
            #receive worker fork
            sub {
                my $cmd = shift;
                my $debug = shift;
                my $noaction = shift;

                print STDERR "# " . ($self->noaction ? "WOULD # " : "" ) . "$cmd\n" if $debug;

                system($cmd)
                    && Mojo::Exception->throw('ERROR: executing receive process') if !$noaction;
            },
            #arguments
            [$cmd, $self->debug, $self->noaction],
            #callback
            sub {
                my ($fc, $err) = @_;
                $self->zLog->debug("receive process on $remote done ($recvPid)");
                Mojo::Exception->throw($err) if $err;
            }
        );
        #spawn event
        $fc->on(
            spawn => sub {
                my ($fc, $pid) = @_;

                $recvPid = $pid;

                $remote =~ s/^[^@]+\@//; #remove username if given
                $self->zLog->debug("receive process on $remote spawned ($pid)");

                push @cmd, [$mbuffer, @{$self->mbufferParam}, $mbufferSize,
                    '-O', "$remote:$mbufferPort"];

                $cmd = $shellQuote->(@cmd);

                print STDERR "# " . ($self->noaction ? "WOULD # " : "" ) . "$cmd\n" if $self->debug;
                return if $self->noaction;

                my $retryCounter = int($self->connectTimeout / $self->sendDelay) + 1;
                while ($retryCounter--){
                    #wait so remote mbuffer has enough time to start listening
                    sleep $self->sendDelay;
                    system($cmd) || last;
                }

                $retryCounter <= 0 && Mojo::Exception->throw("ERROR: cannot send snapshots to $dstDataSet"
                    . ($remote ? " on $remote" : ''));
            }
        );
        #error event
        $fc->on(
            error => sub {
                my ($fc, $err) = @_;
                die $err;
            }
        );
        #start forkcall event loop
        $fc->ioloop->start if !$fc->ioloop->is_running;
    }
    else {
        my @mbCmd = $mbuffer ne 'off' ? ([$mbuffer, @{$self->mbufferParam}, $mbufferSize]) : () ;
        my $recvCmd = [@{$self->priv}, 'zfs', 'recv' , @recvOpt, $dstDataSetPath];

        push @cmd,  $self->$buildRemoteRefArray($remote, @mbCmd, $recvCmd);

        my $cmd = $shellQuote->(@cmd);

        print STDERR "# " . ($self->noaction ? "WOULD # " : "" ) . "$cmd\n" if $self->debug;
	$self->zLog->debug("sending " . $shellQuote->(@cmdSnaps) . "\n");

        system($cmd) && Mojo::Exception->throw("ERROR: cannot send snapshots to $dstDataSetPath"
            . ($remote ? " on $remote" : '')) if !$self->noaction;
    }

    $self->setSnapshotProperties($lastSnapshot, \%snapshotSynced);
    return 1;
}

sub filterPropertyNames {
    # This routine is a helper for getXproperties to allow easy passing of
    # specific properties we are interested to `zfs get`, to optimize some
    # code around that. As an input it can get either:
    # * string that would be passed through as is (after some sanitization);
    # * array of strings that would be concatenated into a comma-separated
    #   string with our name-space propertyPrefix (e.g. "org.znapzend:...")
    #   prepended if needed;
    # * undef for defaulting to 'all'
    # Returns a string safe to pass into `zfs get`
    my $self = shift;
    my $propnames = shift;

    my $propertyPrefix = $self->propertyPrefix;

    if ($propnames) {
        if (ref($propnames) eq 'ARRAY') {
            if (scalar(@$propnames) > 0) {
                my $propstring = '';
                for my $propname (@$propnames) {
                    next if !defined($propname);
                    chomp $propname;

                    if ($propname eq '') {
                        $self->zLog->warn("=== filterPropertyNames(): got an empty propname in array");
                        next;
                    }

                    if ($propname eq 'all') {
                        # TOTHINK: Note that this short-circuiting "as is"
                        # forbids a scenario where we would fetch all zfs
                        # properties to cache them, and then iterate looking
                        # that all specific names have been discovered.
                        # If such needs arise, redefine this here and in
                        # callers checking for 'all' to also handle split(',').
                        $self->zLog->warn("=== filterPropertyNames(): got an 'all' propname in array, any filtering will be moot");
                        return 'all';
                    }

                    if ( $propname =~ /^$propertyPrefix\:/ ) {
                        1; # no-op, all good, use as is
                    } elsif ( $propname =~ /:/ ) {
                        $self->zLog->warn("=== filterPropertyNames(): got a propname not from our namespace: $propname");
                    } else {
                        $propname = $propertyPrefix . ':' . $propname;
                    }

                    if ($propstring eq '') {
                        $propstring = $propname;
                    } else {
                        $propstring .= ',' . $propname;
                    }
                }
                $propnames = $propstring;
                $propnames =~ s/[\s]+//g;
            } else {
                # Got an array, but it was empty
                $propnames = undef; # default below
            }
        } else {
            # Assume string, pass verbatim; strip whitespaces for safety
            $propnames =~ s/[\s]+//g ;
        }
    }

    if ( !(defined($propnames)) || !($propnames) || ($propnames eq '') ) {
        $propnames = 'all';
    }

    return $propnames;
}

sub getDataSetProperties {
    # This routine finds properties of datasets (filesystem, volume) that
    # are name-spaced with our propertyPrefix (e.g. "org.znapzend:...")
    my $self = shift;
    my $dataSet = shift;
    my $recurse = shift; # May be not passed => undef
    my $inherit = shift; # May be not passed => undef

    my @propertyList;
    my $propertyPrefix = $self->propertyPrefix;

    my @list;
    $self->zLog->debug("=== getDataSetProperties():\n"
        . "\trecurse=" . Dumper($recurse)
        . "\tinherit=" . Dumper($inherit)
        . "\tDS=" . Dumper($dataSet)
        . "\tlowmemRecurse=" . $self->lowmemRecurse
        ) if $self->debug;

    if (!defined($recurse)) {
        $recurse = 0;
    }

    if (!defined($inherit)) {
        $inherit = 0;
    }

    # Note: Before the recursive and multiple dataset support we either
    # used the provided dataSet name "as is" trusting it exists (failed
    # later if not), or called listDataSets() to list everything on the
    # system from `zfs` (also ensuring stuff exists). So we still do.
    # Before the recursive the @list must have had individual dataset
    # names, passed directly, or subsequently recursively listed above,
    # to assign into the discovered list elements. So no recursion was
    # needed in the logic below. Now we recurse by default to call `zfs`
    # as rarely as we can and so complete faster. However, on systems
    # with too many datasets this can exhaust the memory available to
    # the process, and/or time out. To defend against this, we optionally
    # can fall back to a big list of individual dataset names found by
    # recursive listDataSets() invocations instead.
    #
    # If both recurse and inherit are specified, behavior depends on
    # the dataset(s) whose name is passed. If the dataset has a local
    # or inherited-from-local backup plan, the recursion stops here.
    # If it has no plan (e.g. pool root dataset), we should recurse and
    # report all children with a "local" backup plan (ignore inherit).
    # Note that listDataSets(), optionally used below for either full
    # or selective listing of datasets seen by the system, does not
    # have a say in this dilemma ("zfs list" does not care about the
    # "source" of a property, only "zfs get" used in this routine does).
    #
    if (defined($dataSet) && $dataSet) {
        if (ref($dataSet) eq 'ARRAY') {
            $self->zLog->debug("=== getDataSetProperties(): Is array...") if $self->debug;
            if ($self->lowmemRecurse && $recurse) {
                my $listds = $self->listDataSets(undef, $dataSet, $recurse);
                if (scalar(@{$listds}) == 0) {
                    $self->zLog->debug("=== getDataSetProperties(): Failed to get data from listDataSets()") if $self->debug;
                    return \@propertyList;
                }
                push (@list, @{$listds});
                $recurse = 0;
                $inherit = 0;
            } else {
                if ( (scalar(@$dataSet) > 0) && (defined(@$dataSet[0])) ) {
                    push (@list, @$dataSet);
                } else {
                    $self->zLog->debug("=== getDataSetProperties(): skip array context: value(s) inside undef...") if $self->debug;
                }
            }
        } else {
            # Assume a string, per usual invocation
            $self->zLog->debug("=== getDataSetProperties(): Is string...") if $self->debug;
            if ($self->lowmemRecurse && $recurse) {
                my $listds = $self->listDataSets(undef, $dataSet, $recurse);
                if (scalar(@{$listds}) == 0) {
                    $self->zLog->debug("=== getDataSetProperties(): Failed to get data from listDataSets()") if $self->debug;
                    return \@propertyList;
                }
                push (@list, @{$listds});
                $recurse = 0;
                $inherit = 0;
            } else {
                if ($dataSet ne '') {
                    push (@list, ($dataSet));
                } else {
                    $self->zLog->debug("=== getDataSetProperties(): skip string context: value inside is empty...") if $self->debug;
                }
            }
        }
    } else {
        $self->zLog->debug("=== getDataSetProperties(): no dataSet argument passed") if $self->debug;
    }

    if (scalar(@list) == 0) {
        $self->zLog->debug("=== getDataSetProperties(): List all local datasets on the system...") if $self->debug;
        my $listds = $self->listDataSets();
        if (scalar(@{$listds}) == 0) {
            $self->zLog->debug("=== getDataSetProperties(): Failed to get data from listDataSets()") if $self->debug;
            return \@propertyList;
        }
        push (@list, @{$listds});
        $recurse = 0;
        $inherit = 0;
    }

    # Iterate every dataset pathname found above, e.g.:
    # * (no args/empty/undef arg) all filesystem/volume datasets on all locally
    #   imported pools, and now recurse==0 and inherit==0 is enforced
    # * (with args and with recursion originally, but lowmemRecurse enabled)
    #   one or more filesystem/volume named datasets and their children found
    #   via zfs list, and now recurse==0 and inherit==0 is enforced
    # * (finally) one or more named datasets from args, with recursion and
    #   inheritance settings to be processed below
    # Depending on inherit (and each dataset referenced in $listElem), pick
    # either datasets that have a backup plan in their arguments with a
    # "local" source, or those that have one inherited from a local (stop
    # at a topmost such then).
    # TODO/FIXME: There may be no support for new backup plan definitions
    # inside a tree that has one above, and/or good grounds for conflicts.
    my %cachedInheritance; # Cache datasets that we know to define znapzend attrs (if inherit mode is used)
    for my $listElem (@list){
        $self->zLog->debug("=== getDataSetProperties(): Looking under '$listElem' with "
            . "zfsGetType='" . $self->zfsGetType . "', "
            . "'$recurse' recursion mode and '$inherit' inheritance mode")
            if $self->debug;
        my %properties;
        # TODO : support "inherit-from-local" mode
        my @cmd = (@{$self->priv}, qw(zfs get -H));
        if ($recurse) {
            push (@cmd, qw(-r));
        }
        if ($inherit) {
            push (@cmd, qw(-s), 'local,inherited');
        } else {
            push (@cmd, qw(-s local));
        }
        if ($self->zfsGetType) {
            push (@cmd, qw(-t), 'filesystem,volume');
        }
        push (@cmd, qw(-o), 'name,property,value,source', 'all', $listElem);
        print STDERR '# ' . join(' ', @cmd) . "\n" if $self->debug;
        # Really a rare event, not to confuse with just
        # getting no properties or bad zfs CLI args
        open my $props, '-|', @cmd or Mojo::Exception->throw("ERROR: could not execute zfs to get properties from $listElem");
        # NOTE: Code below assumes that the listing groups all items of one dataset together
        my $prev_srcds = "";
        my $prevSkipped_srcds = "";
        while (my $prop = <$props>){
            chomp $prop;
            if ( (!$self->zfsGetType) && ($prop =~ /^\S+@\S+\s/) ) {
                # Filter away snapshot properties ASAP
                #$self->zLog->debug("=== getDataSetProperties(): SKIP: '$prop' "
                #    . "because it is a snapshot property") if $self->debug;
                next;
            }
            # NOTE: This regex assumes the dataset names do not have trailing whitespaces
            my ($srcds, $key, $value, $sourcetype, $tail) = $prop =~ /^(.+)\s+\Q$propertyPrefix\E:(\S+)\s+(.+)\s+(local|inherited from )(.*)$/ or next; ### |received|default|-
            # If we are here, the property name (key) is under $propertyPrefix
            # namespace. So this dataset has at least one "interesting" prop...

            # Check if we have inherit mode and should spend time
            # and memory about cached data (selective trimming)
            if ($inherit && $sourcetype ne 'local') {
                # We should trim (non-local) descendants of a listed dataset
                # so as to not define the whole world as if having explicit
                # backup plans configured
                if (defined($cachedInheritance{"$srcds\tattr:source"})) {
                    # We've already seen a line of this and decided to skip it
                    if ($prevSkipped_srcds ne $srcds && $self->debug) {
                        $self->zLog->debug("=== getDataSetProperties(): SKIP: '$srcds' "
                            . "because it is already skipped");
                    }
                    $prevSkipped_srcds = $srcds;
                    next;
                }
                my $srcdsParent = $srcds;
                $srcdsParent =~ s,/[^/]+$,,; # chop off the tail (if any - none on root datasets)
                if (defined($cachedInheritance{"$srcdsParent\tattr:source"})) {
                    if ($prevSkipped_srcds ne $srcds && $self->debug) {
                        # Even if we recurse+inherit, we do not need to return
                        # dozens of backup configurations, one for each child.
                        # The backup activity would recurse from the topmost.
                        $self->zLog->debug("=== getDataSetProperties(): SKIP: '$srcds' "
                            . "because parent config '$srcdsParent' is already listed ("
                            . $cachedInheritance{"$srcdsParent\tattr:source"} .")");
                    }
                    $cachedInheritance{"$srcds\tattr:source"} = "${sourcetype}${tail}";
                    $prevSkipped_srcds = $srcds;
                    # TODO/THINK: Do we assume that a configured dataset has ALL fields
                    # "local" via e.g. znapzendzetup, or if in case of recursion we can
                    # have a mix of inherited and local? Sounds probable for "enabled"
                    # property at least. Maybe we should not chop this away right here,
                    # but do a smarter analysis below in SAVE/SAVE-LAST blocks instead.
                    %properties = ();
                    next;
                }
            }

            $self->zLog->debug("=== getDataSetProperties(): FOUND: '$srcds' => '$key' == '$value' (source: '${sourcetype}${tail}')") if $self->debug;
            if ($srcds ne $prev_srcds) {
                if (%properties && $prev_srcds ne ""){
                    # place source dataset on list, too. so we know where the properties are from...
                    $self->zLog->debug("=== getDataSetProperties(): SAVE: '$prev_srcds'") if $self->debug;
                    $properties{src} = $prev_srcds;
                    # Note: replacing %properties completely proved hard,
                    # it just pushed references to same object for many
                    # really-found datasets. So we make unique copies and
                    # push them instead.
                    my %newProps = %properties;
                    push @propertyList, \%newProps;
                    %properties = ();
                    if ($inherit) {
                        # We've just had a successful save of 1+ attrs we chose
                        # to keep, so should trim descendants above.
                        # TODO: Track somehow else? We effectively save the
                        # source of last seen property here, but are really
                        # interested if this dataset is end of tree walk
                        # (as far as non-local attrs go)...
                        # TODO! Even worse, we now check the new line's source
                        # type and tail, not the prev-dataset's ones. It doesn't
                        # matter much at the moment, as we now only care about it
                        # being set, but can matter after TODO/THINK note above.
                        $cachedInheritance{"$prev_srcds\tattr:source"} = "${sourcetype}${tail}";
                    }
                }
                $prev_srcds = $srcds;
            }
            # We are okay to use this dataset if:
            # * sourcetype == local (any inheritance value)
            # * sourcetype == inherited* and the tail names a dataset whose value for the property is local (and inheritance is allowed)
            # A bit of optimization (speed vs mem tradeoff) is to cache seen
            # property sources (as magic int values); do not bother if not in
            # inheritance mode at all.
            my $inheritKey = "$srcds\t$key"; # TODO: lowmemInherit => "$srcds" ?
            if ($inherit) {
                if (!defined($cachedInheritance{$inheritKey})) {
                    if ($sourcetype eq 'local') {
                        # this DS defines this property
                        $cachedInheritance{$inheritKey} = 1;
                    } else {
                        # inherited from something... technically there are other
                        # categories too (default, received) but we only care to
                        # not run "zfs get" in vain for known misses
                        $cachedInheritance{$inheritKey} = 2;
                    }
                }
            }
            if ($sourcetype eq 'local') {
                $properties{$key} = $value;
            } else {
                # Not a local...
#                print STDERR "NAL: '$inherit' && '$sourcetype' eq 'inherited from ' && '$tail' ne ''\n" if $self->debug;

                if ($inherit && $sourcetype eq 'inherited from ' && $tail ne '') {
                    my $tail_inheritKey = "$tail\t$key"; # TODO: lowmemInherit => "$tail" ?

                    if (!defined($cachedInheritance{$tail_inheritKey})) {
                        # Call zfs get for $tail, fetch all interesting attrs while at it
                        $self->zLog->debug("=== getDataSetProperties(): "
                            . "Looking for '$key' under inheritance source "
                            . "'$tail' to see if it is local there")
                                if $self->debug;
                        my @inh_cmd = (@{$self->priv}, qw(zfs get -H -s local));
                        if ($self->zfsGetType) {
                            push (@inh_cmd, qw(-t), 'filesystem,volume');
                        }
                        # TODO: here and in mock t/zfs, reduce to "-o name,property,source"
                        # or even "-o property,source" when zfsGetType is enabled
                        push (@inh_cmd, qw(-o), 'name,property,value,source',
                            'all', $tail);
                        print STDERR '## ' . join(' ', @inh_cmd) . "\n" if $self->debug;
                        open my $inh_props, '-|', @inh_cmd or Mojo::Exception->throw("ERROR: could not execute zfs to get properties from $tail");
                        while (my $inh_prop = <$inh_props>){
                            chomp $inh_prop;
                            if ( (!$self->zfsGetType) && ($inh_prop =~ /^\S+@\S+\s/) ) {
                                # Filter away snapshot properties ASAP
                                #$self->zLog->debug("=== getDataSetProperties(): SKIP: inherited '$inh_prop' "
                                #    . "because it is a snapshot property") if $self->debug;
                                next;
                            }
                            my ($inh_srcds, $inh_key, $inh_value, $inh_sourcetype, $inh_tail) =
                                $inh_prop =~ /^(.+)\s+\Q$propertyPrefix\E:(\S+)\s+(.+)\s+(local|inherited from |received|default|-)(.*)$/
                                    or next;
                            $self->zLog->debug("=== getDataSetProperties(): FOUND ORIGIN: '$inh_srcds' => '$inh_key' == '$inh_value' (source: '${inh_sourcetype}${inh_tail}')") if $self->debug;
                            my $inh_inheritKey = "$inh_srcds\t$inh_key"; # TODO: lowmemInherit => "$inh_srcds" ?
                            if ($inh_sourcetype eq 'local') {
                                # this DS defines this property
                                $cachedInheritance{$inh_inheritKey} = 1;
                            } else {
                                # inherited from something... technically there are other
                                # categories too (default, received) but we only care to
                                # not run "zfs get" in vain for known misses
                                $cachedInheritance{$inh_inheritKey} = 2;
                            }
                        }
#                    } else {
#                        print STDERR "NAL: '$tail_inheritKey' already defined: " . $cachedInheritance{$tail_inheritKey} . "\n" if $self->debug;
                    }
                    if (defined($cachedInheritance{$tail_inheritKey}) && 1 == $cachedInheritance{$tail_inheritKey}) {
                        # This property comes from a local source
                        if ( $key =~ /^dst_[^_]+$/ ) {
                            # Rewrite destination dataset name shifted same as
                            # this inherited source ($srcds) compared to its
                            # ancestor which the config is inherited from ($tail
                            # in the currently active sanity-checked conditions).
                            if ($srcds =~ /^$tail\/(.+)$/) {
                                $self->zLog->debug("=== getDataSetProperties(): Shifting destination name in config for dataset '$srcds' with configuration inherited from '$tail' : after '$value' will append '/$1'") if $self->debug;
                                $properties{$key} = $value . "/" . $1;
                            } else {
                                # Abort if we can not decide well (better sadly
                                # safe than very-sorry). Not sure if we can get
                                # here... maybe by some zfs clones and promotion?
                                die "The dataset '$srcds' with configuration inherited from '$tail' does not have the latter as ancestor, can't decide how to shift the destination dataset names";
                            }
                        } else {
                            $properties{$key} = $value;
                        }
                    }
                } else {
                    # See some other $props...
                    next;
                }
            }
        }
        if (%properties){
            # place source dataset on list, too. so we know where the properties are from...
            # the last-used dataset is prev_srcds
            $self->zLog->debug("=== getDataSetProperties(): SAVE LAST: '$prev_srcds'") if $self->debug;
            $properties{src} = $prev_srcds;
            my %newProps = %properties;
            push @propertyList, \%newProps;
        }
    }

    $self->zLog->debug("=== getDataSetProperties():\n\tCollected: " . Dumper(@propertyList) ) if $self->debug;

    return \@propertyList;
}

sub setDataSetProperties {
    my $self = shift;
    my $dataSet = shift;
    my $properties = shift;
    my $propertyPrefix = $self->propertyPrefix;

    return 0 if !$self->dataSetExists($dataSet);

    for my $prop (keys %$properties){
        #don't save source dataset as we know the source from the property location
        #also don't save destination validity flags as they are evaluated 'on demand'
        next if $prop eq 'src' || $prop =~ /^dst_[^_]+_valid$/;
        next if !defined($prop);
        next if !defined($properties->{$prop});

        my @cmd = (@{$self->priv}, qw(zfs set), "$propertyPrefix:$prop=$properties->{$prop}", $dataSet);
        print STDERR '# ' . ($self->noaction ? "WOULD # " : "" ) . join(' ', @cmd) . "\n" if $self->debug;
        system(@cmd)
            && Mojo::Exception->throw("ERROR: could not set property $prop on $dataSet") if !$self->noaction;
    }

    return 1;
}

sub deleteDataSetProperties {
    my $self = shift;
    my $dataSet = shift;
    my $propertyPrefix = $self->propertyPrefix;

    return 0 if !$self->dataSetExists($dataSet);
    my $properties = $self->getDataSetProperties($dataSet);

    return 0 if !$properties->[0];

    for my $prop (keys %{$properties->[0]}){
        my @cmd = (@{$self->priv}, qw(zfs inherit), "$propertyPrefix:$prop", $dataSet);
        print STDERR '# ' . ($self->noaction ? "WOULD # " : "" ) . join(' ', @cmd) . "\n" if $self->debug;
        system(@cmd)
            && Mojo::Exception->throw("ERROR: could not reset property $prop on $dataSet") if !$self->noaction;
    }

    return 1;
}

sub getSnapshotProperties {
    # This routine finds properties of snapshots that are name-spaced with
    # our propertyPrefix (e.g. "org.znapzend:...")

    # Note: this code originated as a clone of getDataSetProperties() but
    # that routine grew a lot since then to support recursive, inherited,
    # lowmem and other optional scenarios, and considering dataSet arg as
    # an array of names. Some of those traits may get ported here at least
    # for consistency, where they make sense for ZFS snapshot dataset type.
    my $self = shift;
    my $snapshot = shift;

    # NOTE that it is then up to zfs command to either return only data for the
    # snapshot named in the argument, or also same-named snapshots in children
    # of the dataset this is a snapshot of, so this flag may be effectively
    # ignored by OS, or even actively rejected.
    # TODO: Make magic like for inherit below, to drill into same-named
    # snapshots of datasets that are children of one that $snapshot is a
    # zfs snapshot of.
    my $recurse = shift; # May be not passed => undef

    # NOTE that some versions of zfs do not inherit values from same-named
    # snapshot of a parent dataset, but only from a "real" dataset higher
    # in the data hierarchy, so the "-s inherit" argument may be effectively
    # ignored by OS for the purposes of *such* inheritance. Reasonable modes
    # of sourcing properties include:
    #   0 = only local
    #   1 = local + inherit as defined by zfs
    #   2 = local + recurse into parent that has same snapname
    #   3 = local + inherit as defined by zfs + recurse into parent
    # See struct inheritLevels for reusable definitions.
    my $inherit = shift; # May be not passed => undef => will make a new inheritLevels instance below

    # Limit the request to `zfs get` to only pick out certain properties
    # and save time not-processing stuff the caller will ignore?..
    my $propnames = shift; # May be not passed => undef
    $propnames = $self->filterPropertyNames($propnames); # Returns a string to pass into `zfs get`

    $self->zLog->debug("=== getSnapshotProperties():\n"
        . "\trecurse=" . Dumper($recurse)
        . "\tinherit=" . Dumper($inherit)
        . "\tsnapshot=" . Dumper($snapshot)
        . "\tpropnames=" . Dumper($propnames)
#        . "\tlowmemRecurse=" . $self->lowmemRecurse
        ) if $self->debug;

    if (!defined($recurse)) {
        $recurse = 0;
    }

    if (!defined($inherit)) {
        $inherit = new inheritLevels;
        $inherit->zfs_local(1);
    } else {
        # Data type check
        if ( ! $inherit->isa('inheritLevels') ) {
            $self->zLog->warn("getSnapshotProperties(): inherit argument is not an instance of struct inheritLevels");
            my $newInherit = new inheritLevels;
            if (!$newInherit->reset($inherit)) {
                # caller DID set something, so set a default... local_zfsinherit
                $newInherit->zfs_local(1);
                $newInherit->zfs_inherit(1);
            }
            $inherit = $newInherit;
        }
    }
    my $inhMode = $inherit->getInhMode();

    my %properties;
    my %propertiesInherited;
    my $propertyPrefix = $self->propertyPrefix;

    my @cmd = (@{$self->priv}, qw(zfs get -H));
    if ($recurse) {
        push (@cmd, qw(-r));
    }
    if ($inhMode ne '') {
        push (@cmd, qw(-s), $inhMode);
    }
    if ($self->zfsGetType) {
        push (@cmd, qw(-t snapshot));
    }
    push (@cmd, qw(-o), 'property,value,source', $propnames, $snapshot);

    print STDERR '# ' . join(' ', @cmd) . "\n" if $self->debug;
    open my $props, '-|', @cmd or Mojo::Exception->throw('ERROR: could not get zfs properties of ' . $snapshot);
    while (my $prop = <$props>){
        chomp $prop;
        my ($key, $value, $sourcetype, $tail) = $prop =~ /^\Q$propertyPrefix\E:(\S+)\s+(.+)\s+(local|inherited from |received|default|-)(.*)$/ or next;
        if ($inherit->zfs_inherit and $inherit->snapshot_recurse_parent and $sourcetype =~ /inherited from/) {
            # If we are not doing "snapshot_recurse_parent" then either it
            # is okay to put all values into one bucket initially, or we
            # run on a system where "zfs get" does the snapshot property
            # inheritance the way we need it to here, so manual iteration
            # is not needed (TODO: Make it a user selectable feature).
            # This also impacts the precedence of values set in a snapshot
            # or its recursed same-named snapshots of parent dataset(s)
            # over values that "zfs get" reports as "inherited" (lowest prio).
            # Note we should not have any hits here if zfs_inherit mode
            # is not enabled in the first place, so we filter by that too.
            $propertiesInherited{$key} = $value;
        } else {
            $properties{$key} = $value;
        }
    }
    my $numProps = keys %properties;

    if ($self->debug) {
        if ($numProps > 0) {
            $self->zLog->debug("=== getSnapshotProperties(): GOT '$inhMode' properties of $snapshot : " .Dumper(\%properties) );
        }
    }

    if ($inherit->snapshot_recurse_parent) {
        # For the context we have, inheriting means that we recursively go
        # up through parent datasets that have same-named snapshots as this
        # one, and check if these snapshots have locally defined properties.
        # The value defined nearest to current snapshot is most preferred,
        # so we do not check those "parent snapshots" for what they could
        # have inherited from "real datasets" => will recurse with mode "2".

        # TOTHINK: Is there a loophole for properties defined by some higher
        # level "real" datasets vs. redefinitions in nearer-level snapshots?
        # Perhaps we should first iterate for properties locally defined in
        # a same-named snapshot at some layer of the zfs tree, and only then
        # append what the current (top) target inherits into spots not yet
        # known?

        # First check if we SHOULD recurse, or if from this dataset we have
        # got all the data we were looking for? Probably it is only useful
        # for getting one named property, or if several are named at once
        # by code elsewhere, but still...

        if ( ($propnames ne 'all') && ($numProps > 0) ) {
            # Note that here we only check for our name-spaced properties!
            my @wantedPropnames = grep { /^$propertyPrefix:/ } split(',', $propnames);
            for (@wantedPropnames) {
                s/^$propertyPrefix:// ;
            }
            # we want to see uniq items, if someone listed same thing twice:
            my %seenPropnames = map{$_ => 0} @wantedPropnames;
            @wantedPropnames = keys %seenPropnames;

            $self->zLog->debug("=== getSnapshotProperties(): check wantedPropnames: " .
                Dumper(@wantedPropnames) . " vs collected properties: " .
                Dumper(keys %properties)
                ) if $self->debug;

            if (scalar(@wantedPropnames) == $numProps) {
                # We look for certain property names, and we have the same
                # amount of items in %properties hash, let's dig deeper...
                ###     `use v5.10.1;` or newer for ~~ smartmatch operator
                ### Still warns about experimental perl feature in 5.22...
                #if ($] >= 5.010001) {
                #    if (@wantedPropnames ~~ \%properties) {
                #        $inherit->reset('zfs_local');
                #    }
                #} else {
                    # Old ways...
                    my $uniqHits = 0;
                    for my $key (keys %properties) {
                        if (defined($seenPropnames{$key})) {
                            if ($seenPropnames{$key} == 0) {
                                $uniqHits++;
                            }
                            $seenPropnames{$key}++;
                        }
                    }
                    if ($uniqHits == $numProps) {
                        $inherit->reset('zfs_local');
                    }
                #}
            }
        }
        if (!$inherit->snapshot_recurse_parent) {
            $self->zLog->debug("=== getSnapshotProperties(): Stopping recursion after $snapshot, we have all the properties we needed") if $self->debug;
        }
    }

    if ($inherit->snapshot_recurse_parent) {
        my $parentSnapshot = $snapshot;
        $parentSnapshot =~ s/^(.*)\/[^\/]+(\@.*)$/$1$2/;
        #$self->zLog->debug("=== getSnapshotProperties(): consider iterating from $snapshot up to $parentSnapshot") if $self->debug;
        if ($parentSnapshot ne $snapshot) {
            # Check quietly
            if ($self->snapshotExists($parentSnapshot, 1)) {
                # Go up to root of the pool, without recursing into other children
                # of the parent datasets/snapshots, and without inheriting stuff
                # that is not locally defined properties of a parent (or its parent).
                my $inherit_local_recurseparent = new inheritLevels;
                $inherit_local_recurseparent->snapshot_recurse_parent(1);
                $inherit_local_recurseparent->zfs_local(1);
                my $parentProperties = $self->getSnapshotProperties($parentSnapshot, 0, $inherit_local_recurseparent, $propnames);

                my $numParentProps = keys %$parentProperties;
                if ($numParentProps > 0) {
                    # Merge hash arrays, use existing values as overrides in
                    # case of same-name conflict:
                    $self->zLog->debug("=== getSnapshotProperties(): Merging two property lists from '$parentSnapshot' and '$snapshot' :\n" .
                        "\t" . Dumper(\%$parentProperties) .
                        "\t" . Dumper(\%properties)
                        ) if $self->debug;
                    %properties = (%$parentProperties, %properties);
                    $self->zLog->debug("=== getSnapshotProperties(): Merging returned one property list : " .
                        Dumper(\%properties) ) if $self->debug;
                }
            } else {
                $self->zLog->debug("=== getSnapshotProperties(): Stopping recursion after $snapshot, a $parentSnapshot does not exist") if $self->debug;
            }
        } # else  Got to root, and it was inspected above
    }

    my $numPropertiesInherited = keys %propertiesInherited;
    if ($numPropertiesInherited > 0) {
        $self->zLog->debug("=== getSnapshotProperties(): Merging two property lists - collected from '$snapshot' and same-named snapshots of parent datasets, and what ZFS claims as inherited from ancestors :\n" .
            "\t" . Dumper(\%properties) .
            "\t" . Dumper(\%propertiesInherited)
            ) if $self->debug;
        # Inherited values have lower priority than those local to snapshot or its parents
        %properties = (%propertiesInherited, %properties);
        $self->zLog->debug("=== getSnapshotProperties(): Merging returned one property list : " .
            Dumper(\%properties) ) if $self->debug;
    }

    return \%properties;
}

sub setSnapshotProperties {
    my $self = shift;
    my $snapshot = shift;
    my $properties = shift;
    my $propertyPrefix = $self->propertyPrefix;

    return 0 if !$self->snapshotExists($snapshot);
    for my $prop (keys %$properties){
        my @cmd = (@{$self->priv}, qw(zfs set), "$propertyPrefix:$prop=$properties->{$prop}", $snapshot);
        print STDERR '# ' . ($self->noaction ? "WOULD # " : "" ) . join(' ', @cmd) . "\n" if $self->debug;
        system(@cmd)
            && Mojo::Exception->throw("ERROR: could not set property $prop on $snapshot") if !$self->noaction;
    }

    return 1;
}

sub deleteBackupDestination {
    my $self = shift;
    my $dataSet = shift;
    my $dst = $self->propertyPrefix . ':' . $_[0];

    return 0 if !$self->dataSetExists($dataSet);

    my @cmd = (@{$self->priv}, qw(zfs inherit), $dst, $dataSet);
    print STDERR '# ' . ($self->noaction ? "WOULD # " : "" ) . join(' ', @cmd) . "\n" if $self->debug;
    system(@cmd)
        && Mojo::Exception->throw("ERROR: could not reset property on $dataSet") if !$self->noaction;
    @cmd = (@{$self->priv}, qw(zfs inherit), $dst . '_plan', $dataSet);
    print STDERR '# ' . ($self->noaction ? "WOULD # " : "" ) . join(' ', @cmd) . "\n" if $self->debug;
    system(@cmd)
        && Mojo::Exception->throw("ERROR: could not reset property on $dataSet") if !$self->noaction;

    return 1;
}

sub fileExistsAndExec {
    my $self = shift;
    my $filePath = shift;
    my $remote;

    ($remote, $filePath) = $splitHostDataSet->($filePath);
    my @ssh = $self->$buildRemote($remote, [@{$self->priv}, qw(test -x), $filePath]);

    print STDERR '# ' . join(' ', @ssh) . "\n" if $self->debug;
    return !system(@ssh);
}

sub listPools {
    my $self = shift;
    my $remote = shift;

    my @ssh = $self->$buildRemote($remote, [@{$self->priv}, qw(zpool list -H -o name)]);

    print STDERR '# ' . join(' ', @ssh) . "\n" if $self->debug;
    open my $zPools, '-|', @ssh
        or Mojo::Exception->throw('ERROR: cannot get zpools' . ($remote ? " on $remote" : ''));

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
    my $zpool = shift;
    my $remote;

    ($remote, $zpool) = $splitHostDataSet->($zpool);
    my @ssh = $self->$buildRemote($remote,
        [@{$self->priv}, qw(env LC_MESSAGES=C LC_DATE=C zpool status -v), $zpool]);

    print STDERR '# ' . join(' ', @ssh) . "\n" if $self->debug;
    open my $zpoolStatus, '-|', @ssh or Mojo::Exception->throw("ERROR: cannot get status of $zpool");

    my @status = <$zpoolStatus>;
    chomp(@status);

    return \@status;
}

sub scrubActive {
    my $self = shift;
    #zpool is second argument

    my $scrubProgress = $self->scrubInProgress;

    return grep { /$scrubProgress/ } @{$self->zpoolStatus(@_)};
}

sub usedBySnapshots {
    my $self = shift;
    my $dataSet = shift;
    my $remote;

    return 0 if !$dataSet;

    ($remote, $dataSet) = $splitHostDataSet->($dataSet);
    my @ssh = $self->$buildRemote($remote,
        [@{$self->priv}, qw(zfs get -H -o value usedbysnapshots), $dataSet]);

    print STDERR '# ' . join(' ', @ssh) . "\n" if $self->debug;
    open my $prop, '-|', @ssh
        or Mojo::Exception->throw("ERROR: cannot get usedbysnapshot property of $dataSet");

    my $usedBySnap = <$prop>;
    chomp $usedBySnap if $usedBySnap;

    return $usedBySnap // 0;
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

=head2 snapshotExists

checks if the snapshot exists on localhost or a remote host

=head2 createDataSet

creates a dataset on localhost or a remote host

=head2 listDataSets

lists datasets on (remote-)host

=head2 listSnapshots

returns a list of all snapshots of the dataset

=head2 extractSnapshotNames

returns a list of all snapnames (tags after the "@" character) extracted
from provided array of "dataset@snapshot" values

=head2 listSubDataSets

returns a list of all subdataset including the dataset itself

=head2 createSnapshot

creates a snapshot on localhost or a remote host, optionally recursively

=head2 destroySnapshots

destroys a single snapshot or a list of snapshots on localhost or a remote host, optionally recursively

=head2 lastAndCommonSnapshots

lists the last snapshot on source and the last common snapshot an source and destination and the number of snapshots found on the destination host

=head2 mostRecentCommonSnapshot

gets the name of the most recent common snapshot between source and destination, first by trying to get the actual snapshots, then by checking the dst_*_synced property on each source snapshot if the destination is offline

=head2 sendRecvSnapshots

sends snapshots to a different destination on localhost or a remote host

=head2 getDataSetProperties

gets dataset (filesystem, volume) properties name-spaced with propertyPrefix

=head2 setDataSetProperties

sets dataset (filesystem, volume) properties name-spaced with propertyPrefix

=head2 deleteDataSetProperties

deletes dataset (filesystem, volume) properties name-spaced with propertyPrefix
by inheriting the value from parent (or un-defining the property if no parent
has it)

=head2 getSnapshotProperties

gets snapshot properties name-spaced with propertyPrefix

=head2 setSnapshotProperties

sets snapshot properties name-spaced with propertyPrefix

=head2 deleteBackupDestination

remove a backup destination from a backup plan

=head2 fileExistsAndExec

checks if a file exists and has the executable flag set on localhost or a remote host

=head2 listPools

lists zpools on localhost or a remote host

=head2 startScrub

starts scrub on a zpool

=head2 stopScrub

stops scrub on a zpool

=head2 zpoolStatus

returns status info of a zpool

=head2 scrubActive

returns whether scrub is active on zpool or not

=head2 usedBySnapshots

returns the amount of storage space used by snapshots of a specific dataset

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

S<Tobias Oetiker E<lt>tobi@oetiker.chE<gt>>,
S<Dominik Hassler E<lt>hadfl@cpan.orgE<gt>>

=head1 HISTORY

 2014-06-29 had Flexible snapshot time format
 2014-06-10 had localtime implementation
 2014-06-02 had zpool functionality added
 2014-06-01 had Multi destination backup
 2014-05-30 had Initial Version

=cut
