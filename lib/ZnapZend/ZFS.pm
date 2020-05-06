package ZnapZend::ZFS;

use Mojo::Base -base;
use Mojo::Exception;
use Mojo::IOLoop::ForkCall;
use Data::Dumper;

### attributes ###
has debug           => sub { 0 };
has noaction        => sub { 0 };
has nodestroy       => sub { 1 };
has oracleMode      => sub { 0 };
has recvu           => sub { 0 };
has compressed      => sub { 0 };
has sendRaw         => sub { 0 };
has skipIntermediates => sub { 0 };
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

has zLog            => sub { Mojo::Exception->throw('zLog must be specified at creation time!') };
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
    print STDERR '# ' . join(' ', @ssh) . "\n" if $self->debug;
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
    my $snapshot = shift;
    my $remote;

    #just in case if someone asks to check '';
    return 0 if !$snapshot;

    ($remote, $snapshot) = $splitHostDataSet->($snapshot);
    my @ssh = $self->$buildRemote($remote,
        [@{$self->priv}, qw(zfs list -H -o name -t snapshot), $snapshot]);

    print STDERR '# ' . join(' ', @ssh) . "\n" if $self->debug;
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
    my $snapshotFilter = $_[0] || qr/.*/;
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
        next if $snap !~ /^\Q$dataSet\E\@$snapshotFilter$/;
        push @snapshots, $snap;
    }

    @snapshots = map { ($remote ? "$remote:" : '') . $_ } @snapshots;
    return \@snapshots;
}

sub createDataSet {
    my $self = shift;
    my $dataSet = shift;
    my $remote;

    #just in case if someone asks to check '';
    return 0 if !$dataSet;

    ($remote, $dataSet) = $splitHostDataSet->($dataSet);
    my @ssh = $self->$buildRemote($remote,
        [@{$self->priv}, qw(zfs create -p), $dataSet]);

    print STDERR '# ' . join(' ', @ssh) . "\n" if $self->debug;

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

    print STDERR '# ' .  join(' ', @ssh) . "\n" if $self->debug;

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

            print STDERR '# ' . join(' ', @ssh) . "\n" if $self->debug;
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

        print STDERR '# ' . join(' ', @ssh) . "\n" if $self->debug;
        system(@ssh) && Mojo::Exception->throw("ERROR: cannot destroy snapshot(s) $toDestroy[0]")
            if !($self->noaction || $self->nodestroy);
    }

    return 1;
}

sub lastAndCommonSnapshots {
    my $self = shift;
    my $srcDataSet = shift;
    my $dstDataSet = shift;
    my $snapshotFilter = $_[0] || qr/.*/;

    my $srcSnapshots = $self->listSnapshots($srcDataSet, $snapshotFilter);
    my $dstSnapshots = $self->listSnapshots($dstDataSet, $snapshotFilter);

    return (undef, undef, undef) if !scalar @$srcSnapshots;

    my ($i, $snapTime);
    for ($i = $#{$srcSnapshots}; $i >= 0; $i--){
        ($snapTime) = ${$srcSnapshots}[$i] =~ /^\Q$srcDataSet\E\@($snapshotFilter)/;

        last if grep { /$snapTime/ } @$dstSnapshots;
    }

    return (${$srcSnapshots}[-1], ((grep { /$snapTime/ } @$dstSnapshots)
        ? ${$srcSnapshots}[$i] : undef), scalar @$dstSnapshots);
}

sub sendRecvSnapshots {
    my $self = shift;
    my $srcDataSet = shift;
    my $dstDataSet = shift;
    my $mbuffer = shift;
    my $mbufferSize = shift;
    my $snapFilter = $_[0] || qr/.*/;
    my $recvOpt = $self->recvu ? '-uF' : '-F';
    my $incrOpt = $self->skipIntermediates ? '-i' : '-I';
    my @sendOpt = $self->compressed ? qw(-Lce) : ();
    push @sendOpt, '-w' if $self->sendRaw;

    my $remote;
    my $mbufferPort;

    my $dstDataSetPath;
    ($remote, $dstDataSetPath) = $splitHostDataSet->($dstDataSet);

    my ($lastSnapshot, $lastCommon,$dstSnapCount)
        = $self->lastAndCommonSnapshots($srcDataSet, $dstDataSet, $snapFilter);

    #nothing to do if no snapshot exists on source or if last common snapshot is last snapshot on source
    return 1 if !$lastSnapshot || (defined $lastCommon && ($lastSnapshot eq $lastCommon));

    #check if snapshots exist on destination if there is no common snapshot
    #as this will cause zfs send/recv to fail
    !$lastCommon and $dstSnapCount
        and Mojo::Exception->throw('ERROR: snapshot(s) exist on destination, but no common '
            . "found on source and destination "
            . "clean up destination $dstDataSet (i.e. destroy existing snapshots)");

    ($mbuffer, $mbufferPort) = split /:/, $mbuffer, 2;

    my @cmd;
    if ($lastCommon){
        @cmd = ([@{$self->priv}, 'zfs', 'send', @sendOpt, $incrOpt, $lastCommon, $lastSnapshot]);
    }
    else{
        @cmd = ([@{$self->priv}, 'zfs', 'send', @sendOpt, $lastSnapshot]);
    }

    #if mbuffer port is set, run in 'network mode'
    if ($remote && $mbufferPort && $mbuffer ne 'off'){
        my $recvPid;

        my @recvCmd = $self->$buildRemoteRefArray($remote, [$mbuffer, @{$self->mbufferParam},
            $mbufferSize, '-4', '-I', $mbufferPort], [@{$self->priv}, 'zfs', 'recv', $recvOpt, $dstDataSetPath]);

        my $cmd = $shellQuote->(@recvCmd);

        my $fc = Mojo::IOLoop::ForkCall->new;
        $fc->run(
            #receive worker fork
            sub {
                my $cmd = shift;
                my $debug = shift;
                my $noaction = shift;

                print STDERR "# $cmd\n" if $debug;

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

                print STDERR "# $cmd\n" if $self->debug;
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
        my $recvCmd = [@{$self->priv}, 'zfs', 'recv' , $recvOpt, $dstDataSetPath];

        push @cmd,  $self->$buildRemoteRefArray($remote, @mbCmd, $recvCmd);

        my $cmd = $shellQuote->(@cmd);
        print STDERR "# $cmd\n" if $self->debug;

        system($cmd) && Mojo::Exception->throw("ERROR: cannot send snapshots to $dstDataSetPath"
            . ($remote ? " on $remote" : '')) if !$self->noaction;
    }

    return 1;
}

sub getDataSetProperties {
    my $self = shift;
    my $dataSet = shift;
    my $recurse = shift; # May be not passed => undef
    my $inherit = shift; # May be not passed => undef

    my @propertyList;
    my $propertyPrefix = $self->propertyPrefix;

    my @list;
    print STDERR "=== getDataSetProperties():"
        . "\n\trecurse=" . Dumper($recurse)
        . "\n\tinherit=" . Dumper($inherit)
        . "\n\tDS=" . Dumper($dataSet)
        . "\n\tlowmemRecurse=" . $self->lowmemRecurse . "\n"
             if $self->debug;

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
    # "source" of an attribute, only "zfs get" used in this routine does).
    #
    if (defined($dataSet) && $dataSet) {
        if (ref($dataSet) eq 'ARRAY') {
            print STDERR "=== getDataSetProperties(): Is array...\n" if $self->debug;
            if ($self->lowmemRecurse && $recurse) {
                my $listds = $self->listDataSets(undef, $dataSet, $recurse);
                if (scalar(@{$listds}) == 0) {
                    print STDERR "=== getDataSetProperties(): Failed to get data from listDataSets()\n" if $self->debug;
                    return \@propertyList;
                }
                push (@list, @{$listds});
                $recurse = 0;
                $inherit = 0;
            } else {
                if ( (scalar(@$dataSet) > 0) && (defined(@$dataSet[0])) ) {
                    push (@list, @$dataSet);
                } else {
                    print STDERR "=== getDataSetProperties(): skip array context: value(s) inside undef...\n" if $self->debug;
                }
            }
        } else {
            # Assume a string, per usual invocation
            print STDERR "=== getDataSetProperties(): Is string...\n" if $self->debug;
            if ($self->lowmemRecurse && $recurse) {
                my $listds = $self->listDataSets(undef, $dataSet, $recurse);
                if (scalar(@{$listds}) == 0) {
                    print STDERR "=== getDataSetProperties(): Failed to get data from listDataSets()\n" if $self->debug;
                    return \@propertyList;
                }
                push (@list, @{$listds});
                $recurse = 0;
                $inherit = 0;
            } else {
                if ($dataSet ne '') {
                    push (@list, ($dataSet));
                } else {
                    print STDERR "=== getDataSetProperties(): skip string context: value inside is empty...\n" if $self->debug;
                }
            }
        }
    } else {
        print STDERR "=== getDataSetProperties(): no dataSet argument passed\n" if $self->debug;
    }

    if (scalar(@list) == 0) {
        print STDERR "=== getDataSetProperties(): List all local datasets on the system...\n" if $self->debug;
        my $listds = $self->listDataSets();
        if (scalar(@{$listds}) == 0) {
            print STDERR "=== getDataSetProperties(): Failed to get data from listDataSets()\n" if $self->debug;
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
        print STDERR "=== getDataSetProperties(): Looking under '$listElem' with "
            . "zfsGetType='" . $self->zfsGetType . "', "
            . "'$recurse' recursion mode and '$inherit' inheritance mode\n"
            if $self->debug;
        my %properties;
        # TODO : support "inherit-from-local" mode
        my @cmd = (@{$self->priv}, qw(zfs get -H));
        if ($inherit) {
            push (@cmd, qw(-s), 'local,inherited');
        } else {
            push (@cmd, qw(-s local));
        }
        if ($self->zfsGetType) {
            push (@cmd, qw(-t), 'filesystem,volume');
        }
        if ($recurse) {
            push (@cmd, qw(-r));
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
                #print STDERR "=== getDataSetProperties(): SKIP: '$prop' "
                #    . "because it is a snapshot property\n" if $self->debug;
                next;
            }
            # NOTE: This regex assumes the dataset names do not have trailing whitespaces
            my ($srcds, $key, $value, $sourcetype, $tail) = $prop =~ /^(.+)\s+\Q$propertyPrefix\E:(\S+)\s+(.+)\s+(local|inherited from )(.*)$/ or next; ### |received|default|-
            # If we are here, the attribute name (key) is under $propertyPrefix
            # namespace. So this dataset has at least one "interesting" attr...

            # Check if we have inherit mode and should spend time
            # and memory about cached data (selective trimming)
            if ($inherit && $sourcetype ne 'local') {
                # We should trim (non-local) descendants of a listed dataset
                # so as to not define the whole world as if having explicit
                # backup plans configured
                if (defined($cachedInheritance{"$srcds\tattr:source"})) {
                    # We've already seen a line of this and decided to skip it
                    if ($prevSkipped_srcds ne $srcds && $self->debug) {
                        print STDERR "=== getDataSetProperties(): SKIP: '$srcds' "
                            . "because it is already skipped\n";
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
                        print STDERR "=== getDataSetProperties(): SKIP: '$srcds' "
                            . "because parent config '$srcdsParent' is already listed ("
                            . $cachedInheritance{"$srcdsParent\tattr:source"} .")\n";
                    }
                    $cachedInheritance{"$srcds\tattr:source"} = "${sourcetype}${tail}";
                    $prevSkipped_srcds = $srcds;
                    # TODO/THINK: Do we assume that a configured dataset has ALL fields
                    # "local" via e.g. znapzendzetup, or if in case of recursion we can
                    # have a mix of inherited and local? Sounds probable for "enabled"
                    # attribute at least. Maybe we should not chop this away right here,
                    # but do a smarter analysis below in SAVE/SAVE-LAST blocks instead.
                    %properties = ();
                    next;
                }
            }

            print STDERR "=== getDataSetProperties(): FOUND: '$srcds' => '$key' == '$value' (source: '${sourcetype}${tail}')\n" if $self->debug;
            if ($srcds ne $prev_srcds) {
                if (%properties && $prev_srcds ne ""){
                    # place source dataset on list, too. so we know where the properties are from...
                    print STDERR "=== getDataSetProperties(): SAVE: '$prev_srcds'\n" if $self->debug;
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
                        # source of last seen attr here, but are really
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
            # * sourcetype == inherited* and the tail names a dataset whose value for the attribute is local (and inheritance is allowed)
            # A bit of optimization (speed vs mem tradeoff) is to cache seen
            # attr sources (as magic int values); do not bother if not in
            # inheritance mode at all.
            my $inheritKey = "$srcds\t$key"; # TODO: lowmemInherit => "$srcds" ?
            if ($inherit) {
                if (!defined($cachedInheritance{$inheritKey})) {
                    if ($sourcetype eq 'local') {
                        # this DS defines this attr
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
                        print STDERR "=== getDataSetProperties(): "
                            . "Looking for '$key' under inheritance source "
                            . "'$tail' to see if it is local there\n"
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
                                #print STDERR "=== getDataSetProperties(): SKIP: inherited '$inh_prop' "
                                #    . "because it is a snapshot property\n" if $self->debug;
                                next;
                            }
                            my ($inh_srcds, $inh_key, $inh_value, $inh_sourcetype, $inh_tail) =
                                $inh_prop =~ /^(.+)\s+\Q$propertyPrefix\E:(\S+)\s+(.+)\s+(local|inherited from |received|default|-)(.*)$/
                                    or next;
                            print STDERR "=== getDataSetProperties(): FOUND ORIGIN: '$inh_srcds' => '$inh_key' == '$inh_value' (source: '${inh_sourcetype}${inh_tail}')\n" if $self->debug;
                            my $inh_inheritKey = "$inh_srcds\t$inh_key"; # TODO: lowmemInherit => "$inh_srcds" ?
                            if ($inh_sourcetype eq 'local') {
                                # this DS defines this attr
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
                        # This attr comes from a local source
                        if ( $key =~ /^dst_[^_]+$/ ) {
                            # Rewrite destination dataset name shifted same as
                            # this inherited source ($srcds) compared to its
                            # ancestor which the config is inherited from ($tail
                            # in the currently active sanity-checked conditions).
                            if ($srcds =~ /^$tail\/(.+)$/) {
                                print STDERR "=== getDataSetProperties(): Shifting destination name in config for dataset '$srcds' with configuration inherited from '$tail' : after '$value' will append '/$1'\n" if $self->debug;
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
            print STDERR "=== getDataSetProperties(): SAVE LAST: '$prev_srcds'\n" if $self->debug;
            $properties{src} = $prev_srcds;
            my %newProps = %properties;
            push @propertyList, \%newProps;
        }
    }

    print STDERR "=== getDataSetProperties():\n\tCollected: " . Dumper(@propertyList) . "\n" if $self->debug;

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
        print STDERR '# ' . join(' ', @cmd) . "\n" if $self->debug;
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
        print STDERR '# ' . join(' ', @cmd) . "\n" if $self->debug;
        system(@cmd)
            && Mojo::Exception->throw("ERROR: could not reset property $prop on $dataSet") if !$self->noaction;
    }

    return 1;
}

sub deleteBackupDestination {
    my $self = shift;
    my $dataSet = shift;
    my $dst = $self->propertyPrefix . ':' . $_[0];

    return 0 if !$self->dataSetExists($dataSet);

    my @cmd = (@{$self->priv}, qw(zfs inherit), $dst, $dataSet);
    print STDERR '# ' . join(' ', @cmd) . "\n" if $self->debug;
    system(@cmd)
        && Mojo::Exception->throw("ERROR: could not reset property on $dataSet") if !$self->noaction;
    @cmd = (@{$self->priv}, qw(zfs inherit), $dst . '_plan', $dataSet);
    print STDERR '# ' . join(' ', @cmd) . "\n" if $self->debug;
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

=head2 listSubDataSets

returns a list of all subdataset including the dataset itself

=head2 createSnapshot

creates a snapshot on localhost or a remote host, optionally recursively

=head2 destroySnapshots

destroys a single snapshot or a list of snapshots on localhost or a remote host, optionally recursively

=head2 lastAndCommonSnapshots

lists the last snapshot on source and the last common snapshot an source and destination and the number of snapshots found on the destination host

=head2 sendRecvSnapshots

sends snapshots to a different destination on localhost or a remote host

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
