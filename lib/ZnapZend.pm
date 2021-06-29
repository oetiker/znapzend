package ZnapZend;

use Mojo::Base -base;
use Mojo::IOLoop::ForkCall;
use Mojo::Log;
use ZnapZend::Config;
use ZnapZend::ZFS;
use ZnapZend::Time;
use POSIX qw(setsid SIGTERM SIGKILL WNOHANG);
use Scalar::Util qw(blessed);
use Sys::Syslog;
use File::Basename;
use Data::Dumper;

### loglevels ###
my %logLevels = (
    debug   => 'debug',
    info    => 'info',
    warn    => 'warning',
    error   => 'err',
    fatal   => 'alert',
);

### attributes ###

has debug                   => sub { 0 };
has resume          => sub { 0 };
has noaction                => sub { 0 };
has nodestroy               => sub { 0 };
has oracleMode              => sub { 0 };
has recvu                   => sub { 0 };
has compressed              => sub { 0 };
has sendRaw                 => sub { 0 };
has skipIntermediates       => sub { 0 };
has forbidDestRollback      => sub { 0 };
has lowmemRecurse           => sub { 0 };
has rootExec                => sub { q{} };
has zfsGetType              => sub { 0 };
has connectTimeout          => sub { 30 };
has runonce                 => sub { 0 };
has recursive               => sub { 0 };
has inherited               => sub { 0 };
has since                   => sub { 0 };
has dataset                 => sub { undef };
has daemonize               => sub { 0 };
has loglevel                => sub { q{debug} };
has logto                   => sub { q{} };
has pidfile                 => sub { q{} };
has forcedSnapshotSuffix    => sub { q{} };
has defaultPidFile          => sub { q{/var/run/znapzend.pid} };
has terminate               => sub { 0 };
has autoCreation            => sub { 0 };
has timeWarp                => sub { undef };
has nodelay                 => sub { 0 };
has skipOnPreSnapCmdFail    => sub { 0 };
has skipOnPreSendCmdFail    => sub { 0 };
has cleanOffline            => sub { 0 };
has 'mailErrorSummaryTo';
has backupSets              => sub { [] };


has zConfig => sub {
    my $self = shift;
    ZnapZend::Config->new(debug => $self->debug, noaction => $self->noaction,
                          rootExec => $self->rootExec, timeWarp => $self->timeWarp,
                          zfsGetType => $self->zfsGetType,
                          zLog => $self->zLog);
};

has zZfs => sub {
    my $self = shift;
    ZnapZend::ZFS->new(debug => $self->debug, noaction => $self->noaction,
        nodestroy => $self->nodestroy, oracleMode => $self->oracleMode,
        resume => $self->resume,
        recvu => $self->recvu, connectTimeout => $self->connectTimeout,
        lowmemRecurse => $self->lowmemRecurse, skipIntermediates => $self->skipIntermediates,
        rootExec => $self->rootExec, zfsGetType => $self->zfsGetType,
        zLog => $self->zLog, compressed => $self->compressed,
        sendRaw => $self->sendRaw, forbidDestRollback => $self->forbidDestRollback);
};

has zTime => sub { ZnapZend::Time->new(timeWarp=>shift->timeWarp) };

has zLog => sub {
    my $self = shift;

    #check if we are logging to syslog
    my ($syslog) = $self->logto =~ /^syslog::(\w+)$/;
    # logging defaults to syslog::daemon (STDERR if runonce)
    $syslog = 'daemon' if !$self->logto && !$self->runonce;

    #make level mojo conform
    my ($level) = grep { $logLevels{$_} eq $self->loglevel } keys %logLevels
        or die "ERROR: only log levels '" . join("', '", values %logLevels)
            . "' are supported\n";

    my $log = Mojo::Log->new(
        path  => $syslog                         ? '/dev/null'
               : $self->runonce && !$self->logto ? undef
               :                                   $self->logto,
        level => $level
    );

    $syslog && do {
        $log->unsubscribe('message');
        #add syslog handler if either syslog is explicitly specified or no logfile is given
        openlog(basename($0), 'cons,pid', $syslog);
        $log->on(
            message => sub {
                my ($log, $level, @lines) = @_;
                syslog($logLevels{$level}, @lines) if $log->is_level($level);
            }
        );
    };

    return $log;
};

### private methods ###
my $killThemAll = sub {
    my $self = shift;

    $self->zLog->info("terminating znapzend (PID=$$) ...");
    #set termination flag
    $self->terminate(1);

    Mojo::IOLoop->reset;

    for my $backupSet (@{$self->backupSets}){
        kill (SIGTERM, $backupSet->{snap_pid}) if $backupSet->{snap_pid};
        kill (SIGTERM, $backupSet->{send_pid}) if $backupSet->{send_pid};
    }
    sleep 1;
    for my $backupSet (@{$self->backupSets}){
        waitpid($backupSet->{snap_pid}, WNOHANG)
            || kill(SIGKILL, $backupSet->{snap_pid}) if $backupSet->{snap_pid};
        waitpid($backupSet->{send_pid}, WNOHANG)
            || kill(SIGKILL, $backupSet->{send_pid}) if $backupSet->{send_pid};
    }

    $self->zLog->info("znapzend (PID=$$) terminated.");
    exit 0;
};

my $refreshBackupPlans = sub {
    my $self = shift;
    my $recurse = shift;
    my $inherit = shift;
    my $dataSet = shift;

    $self->zLog->info('refreshing backup plans' .
        (defined($dataSet) ? ' for dataset "' . $dataSet . '"' : '') .
        ' ...');
    $self->backupSets($self->zConfig->getBackupSetEnabled($recurse, $inherit, $dataSet));

    ($self->backupSets && @{$self->backupSets})
        or die "No backup set defined or enabled, yet. run 'znapzendzetup' to setup znapzend\n";

    for my $backupSet (@{$self->backupSets}){
        $backupSet->{srcPlanHash} = $self->zTime->backupPlanToHash($backupSet->{src_plan});
        #check destination for remote pre-command
        for (keys %$backupSet){
            my ($key) = /^dst_([^_]+)_precmd$/ or next;

            #perform pre-send-command if any
            if ($backupSet->{"dst_$key" . '_precmd'} && $backupSet->{"dst_$key" . '_precmd'} ne 'off'){
                if ($backupSet->{"dst_$key" . '_enabled'} && $backupSet->{"dst_$key" . '_enabled'} eq 'off'){
                    $self->zLog->info("Skipping pre-send-command for disabled destination " . $backupSet->{"dst_$key"});
                } else {
                    # set env var for script to use
                    local $ENV{WORKER} = $backupSet->{"dst_$key"} . '-refresh';
                    $self->zLog->info("running pre-send-command for " . $backupSet->{"dst_$key"});

                    system($backupSet->{"dst_$key" . '_precmd'})
                        && $self->zLog->warn("command \'" . $backupSet->{"dst_$key" . '_precmd'} . "\' failed");
                    # clean up env var
                    delete $ENV{WORKER};
                }
            }
        }
    }

    for my $backupSet (@{$self->backupSets}){
        $backupSet->{srcPlanHash} = $self->zTime->backupPlanToHash($backupSet->{src_plan});
        #create backup hashes for all destinations
        for (keys %$backupSet){
            my ($key) = /^dst_([^_]+)_plan$/ or next;

            #check if destination exists (i.e. is valid) otherwise recheck as dst might be online, now
            if (!$backupSet->{"dst_$key" . '_valid'}){

                $backupSet->{"dst_$key" . '_valid'} =
                    $self->zZfs->dataSetExists($backupSet->{"dst_$key"}) or do {

                    if ($self->autoCreation && !$self->sendRaw) {
                        my ($zpool) = $backupSet->{"dst_$key"} =~ /(^[^\/]+)\//;

                        # check if we can access destination zpool, if so create parent dataset
                        $self->zZfs->dataSetExists($zpool) && do {
                            $self->zLog->info("creating destination dataset '" . $backupSet->{"dst_$key"} . "'...");

                            $backupSet->{"dst_$key" . '_valid'} =
                                $self->zZfs->createDataSet($backupSet->{"dst_$key"});

                            if ($backupSet->{"dst_$key" . '_valid'}) {
                                $backupSet->{"dst_$key" . '_justCreated'} = 1;
                            }
                        };
                    }
                    $backupSet->{"dst_$key" . '_valid'} or
                        $self->zLog->warn("destination '" . $backupSet->{"dst_$key"}
                            . "' does not exist or is offline. will be rechecked every run..."
                            . ( $self->autoCreation ? "" : " Consider running znapzend --autoCreation" ) );
                };
            }
            $backupSet->{"dst$key" . 'PlanHash'}
                = $self->zTime->backupPlanToHash($backupSet->{"dst_$key" . '_plan'});
        }
        $backupSet->{interval}   = $self->zTime->getInterval($backupSet->{srcPlanHash});
        # NOTE that actual cleanup operations below exclude $self->since (as regex pattern) if defined.
        $backupSet->{snapCleanFilter} = $self->zTime->getSnapshotFilter($backupSet->{tsformat});
        # Due to support of possible intermediate snapshots named outside the
        # generated configured pattern (tsformat), to send (and not destroy on
        # destination) the arbitrary names, and find last common ones properly,
        # we should match all snap names here and there.
        ### TODO: Revise the options commented away below, as they might only
        ### apply to different situations.
        ###   $backupSet->{snapSendFilter} = $self->zTime->getSnapshotFilter($backupSet->{tsformat});
        ###   if ($self->since) { $backupSet->{snapSendFilter} = "(".$backupSet->{snapSendFilter}."|".$self->since.")"; }
        $backupSet->{snapSendFilter} = qr/.*/;
#        $backupSet->{snapSendFilter} = $backupSet->{snapCleanFilter};
#        if (defined($self->forcedSnapshotSuffix) && $self->forcedSnapshotSuffix ne '') {
#            # TODO : Should this include ^ (or ^.*@) and $ boundaries?
#            #$backupSet->{snapSendFilter} = '(' . $backupSet->{snapSendFilter} . '|' . $self->forcedSnapshotSuffix . ')';
#        }
        $backupSet->{UTC}        = $self->zTime->useUTC($backupSet->{tsformat});
        $self->zLog->info("found a valid backup plan for $backupSet->{src}...");
    }
    for my $backupSet (@{$self->backupSets}){
        $backupSet->{srcPlanHash} = $self->zTime->backupPlanToHash($backupSet->{src_plan});
        #check destination for remote post-command
        for (keys %$backupSet){
            my ($key) = /^dst_([^_]+)_pstcmd$/ or next;

            #perform post-send-command if any
            if ($backupSet->{"dst_$key" . '_pstcmd'} && $backupSet->{"dst_$key" . '_pstcmd'} ne 'off'){
                if ($backupSet->{"dst_$key" . '_enabled'} && $backupSet->{"dst_$key" . '_enabled'} eq 'off'){
                    $self->zLog->info("Skipping post-send-command for disabled destination " . $backupSet->{"dst_$key"});
                } else {
                    # set env var for script to use
                    local $ENV{WORKER} = $backupSet->{"dst_$key"} . '-refresh';
                    $self->zLog->info("running post-send-command for " . $backupSet->{"dst_$key"});

                    system($backupSet->{"dst_$key" . '_pstcmd'})
                        && $self->zLog->warn("command \'" . $backupSet->{"dst_$key" . '_pstcmd'} . "\' failed");
                    # clean up env var
                    delete $ENV{WORKER};
                }
            }
        }
    }
};

my $sendRecvCleanup = sub {
    my $self = shift;
    my $backupSet = shift;
    my $timeStamp = shift;

    #no HUP handler in child
    $SIG{HUP} = 'IGNORE';

    if ($self->nodelay && $backupSet->{zend_delay}) {
        $self->zLog->warn("CLI option --nodelay was requested, so ignoring backup plan option 'zend-delay' (was $backupSet->{zend_delay}) on backupSet $backupSet->{src}");
        $backupSet->{zend_delay} = undef;
    }

    if (defined($backupSet->{zend_delay})) {
        chomp $backupSet->{zend_delay};
        if (!($backupSet->{zend_delay} =~ /^\d+$/)) {
            $self->zLog->warn("Backup plan option 'zend-delay' has an invalid value ('$backupSet->{zend_delay}' is not a number) on backupSet $backupSet->{src}, ignored");
            $backupSet->{zend_delay} = undef;
        } else {
            if($backupSet->{zend_delay} > 0) {
                $self->zLog->info("waiting $backupSet->{zend_delay} seconds before sending snaps on backupSet $backupSet->{src}...");
                sleep $backupSet->{zend_delay};
                $self->zLog->info("resume sending action on backupSet $backupSet->{src}");
            }
        }
    }

    my @snapshots;
    my $toDestroy;
    my @sendFailed; # List of messages about failed sends
    my $startTime = time;
    $self->zLog->info('starting work on backupSet ' . $backupSet->{src});

    #get all sub datasets of source filesystem; need to send them all individually if recursive
    my $srcSubDataSets = $backupSet->{recursive} eq 'on'
        ? $self->zZfs->listSubDataSets($backupSet->{src}) : [ $backupSet->{src} ];

    #loop through all destinations
    for my $dst (sort grep { /^dst_[^_]+$/ } keys %$backupSet){
        my ($key) = $dst =~ /dst_([^_]+)$/;
        my $thisSendFailed = 0; # Track if we don't want THIS destination cleaned up

        #allow users to disable some destinations (e.g. reserved/templated
        #backup plan config items, or known broken targets) without deleting
        #them outright. Note it is likely that the common (automatic) snapshots
        #between source and that destination would disappear over time, making
        #incremental sync impossible at some point in the future.
        if ($backupSet->{"dst_$key" . '_enabled'} && $backupSet->{"dst_$key" . '_enabled'} eq 'off'){
            $self->zLog->info("Skipping disabled destination " . $backupSet->{"dst_$key"}
                . ". Note that you would likely need to recreate the backup data tree there");
            next;
        }

        #check destination for pre-send-command
        if ($backupSet->{"dst_$key" . '_precmd'} && $backupSet->{"dst_$key" . '_precmd'} ne 'off'){
            local $ENV{WORKER} = $backupSet->{"dst_$key"};
            $self->zLog->info("running pre-send-command for " . $backupSet->{"dst_$key"});

            my $ev  = system($backupSet->{"dst_$key" . '_precmd'});
            delete $ENV{WORKER};

            if ($ev){
                $self->zLog->warn("pre-send-command \'" . $backupSet->{"dst_$key" . '_precmd'} . "\' failed");
                if ($self->skipOnPreSendCmdFail) {
                    my $errmsg = "skipping " . $backupSet->{"dst_$key"} . " due to pre-send-command failure";
                    $self->zLog->warn($errmsg);
                    push (@sendFailed, $errmsg);
                    $thisSendFailed = 1;
                    next;
                }
            }
        }

        #recheck non valid dst as it might be online, now
        if (!$backupSet->{"dst_$key" . '_valid'}) {

            $backupSet->{"dst_$key" . '_valid'} =
                $self->zZfs->dataSetExists($backupSet->{"dst_$key"}) or do {

                if ($self->autoCreation && !$self->sendRaw) {
                    my ($zpool) = $backupSet->{"dst_$key"} =~ /(^[^\/]+)\//;

                    # check if we can access destination zpool, if so create parent dataset
                    $self->zZfs->dataSetExists($zpool) && do {
                        $self->zLog->info("creating destination dataset '" . $backupSet->{"dst_$key"} . "'...");

                        $backupSet->{"dst_$key" . '_valid'} =
                            $self->zZfs->createDataSet($backupSet->{"dst_$key"});

                        if ($backupSet->{"dst_$key" . '_valid'}) {
                            $backupSet->{"dst_$key" . '_justCreated'} = 1;
                        }
                    };
                }
                ( $backupSet->{"dst_$key" . '_valid'} || ($self->sendRaw && $self->autoCreation) ) or do {
                    my $errmsg = "destination '" . $backupSet->{"dst_$key"}
                        . "' does not exist or is offline. ignoring it for this round...";
                    $self->zLog->warn($errmsg);
                    push (@sendFailed, $errmsg);
                    $thisSendFailed = 1;
                    next;
                };
            };
        }

        #sending loop through all subdatasets
        #note: given that transfers can take long even locally, we do not
        #really want recursive sending (so retries can go dataset by dataset)
        #also, we can disable individual children of recursive ZFS datasets
        #from being snapshot/sent by setting property "org.znapzend:enabled"
        #to "off" on them
        for my $srcDataSet (@$srcSubDataSets){
            my $dstDataSet = $srcDataSet;
            $dstDataSet =~ s/^\Q$backupSet->{src}\E/$backupSet->{$dst}/;

            $self->zLog->debug('sending snapshots from ' . $srcDataSet . ' to ' . $dstDataSet);
            {
                local $@;
                eval {
                    local $SIG{__DIE__};
                    $self->zLog->debug('Are we sending "--since"? '.
                        'since=="' . $self->since . '"'.
                        ', skipIntermediates=="' . $self->skipIntermediates . '"' .
                        ', forbidDestRollback=="' . $self->forbidDestRollback . '"' .
                        ', justCreated=="' . ( $backupSet->{"dst_$key" . '_justCreated'} ? "true" : "false" ) . '"'
                        ) if $self->debug;
                    if ($self->since) {
                        # Make sure that if we use the "--sinceForced=X" or
                        # "--since=X" option, this named snapshot exists (or
                        # appears) in the destination dataset history of
                        # snapshots.
                        # Note if "X" does not yet exist on destination AND
                        # if there are newer than "X" snapshots on destination,
                        # they would be removed to allow receiving "X" with
                        # the "--sinceForced=X" mode, but not with "--since=X"
                        # which would only add it if it is an intermediate snap.

                        # FIXME: Implementation below seems wasteful for I/Os
                        # doing many "zfs list" calls (at least metadata is
                        # cached by the OSes involved). Luckily "--since=X"
                        # is not default and for PoC this should be readable.
                        # Largely copied from lastAndCommonSnapshots() and
                        # listSnapshots() routines.

                        # In some cases we do not have to actively replicate "X":
                        # 1) "X" does not exist in history of src, no-op
                        if ($self->zZfs->snapshotExists($srcDataSet . "@" . $self->since)) {
                        # 2) "X" exists in history of both src and dst, no-op
                            if (!$self->zZfs->snapshotExists($dstDataSet . "@" . $self->since)) {
                        # ...So "X" exists in src and not in dst; where is it
                        # in our history relative to latest common snapshot?
                        # Is there one at all?

                                ### Inspect ALL snapshots in this case, not just auto's
                                ### my $snapSendFilter = $backupSet->{snapSendFilter};
                                my $snapSendFilter = qr/.*/;

                                my $srcSnapshots = $self->zZfs->listSnapshots($srcDataSet, $snapSendFilter);
                                if (scalar @$srcSnapshots) {
                                    my $dstSnapshots = $self->zZfs->listSnapshots($dstDataSet, $snapSendFilter);

                                    my $i;
                                    my $snapName;
                                    my $lastCommon; # track the newest common snapshot, if any
                                    my $lastCommonNum; # Flips to "i" if we had any common snapshots
                                    my $firstCommon; # track the oldest known common snapshot (if we can roll back to use it)
                                    my $firstCommonNum ; # Flips to "i" if we had any common snapshots
                                    my $seenX; # Flips to "i" if we saw "X" before (or as) the newest common snapshot, looking from newest snapshots in src
                                    my $seenD; # Flips to "i" if we saw "X" in DST during this search
                                    # Note that depending on conditions, we might not look through ALL snapnames and stop earlier when we saw enough
                                    for ($i = $#{$srcSnapshots}; $i >= 0; $i--){
                                        ($snapName) = ${$srcSnapshots}[$i] =~ /^\Q$srcDataSet\E\@($snapSendFilter)/;
                                        #print STDERR "=== LOOKING: #$i : FQSN: ${$srcSnapshots}[$i] => '$snapName' cf. '" . $self->since ."'\n" if $self->debug;
                                        if ( $snapName eq $self->since || $snapName =~ m/^$self->since$/ ) {
                                            $seenX = $i;
                                            print STDERR "+++ SEENSRC: #$i : FQSN: ${$srcSnapshots}[$i] => '$snapName' cf. '" . $self->since ."'\n" if $self->debug;
                                        }
                                        if ( grep { /\@$snapName$/ } @$dstSnapshots ) {
                                            if ( $snapName eq $self->since || $snapName =~ m/^$self->since$/ ) {
                                                $seenD = $i;
                                                print STDERR "+++ SEENDST: #$i : FQSN: ${$srcSnapshots}[$i] => '$snapName' cf. '" . $self->since ."'\n" if $self->debug;
                                            }
                                            $firstCommonNum = $i;
                                            $firstCommon = ${$srcSnapshots}[$i];
                                            print STDERR "||| COMMON : #$i : FQSN: ${$srcSnapshots}[$i] => '$snapName' cf. '" . $self->since ."'\n" if $self->debug;
                                            if (!defined($lastCommon)) {
                                                # This may be our last iteration here, or not...
                                                $lastCommonNum = $i;
                                                $lastCommon = ${$srcSnapshots}[$i];
                                                # Handle the situation when we have a --sinceForced=X
                                                # request, so the "X" has to be (or appear) in history
                                                # of destination dataset. Even if we found the newest
                                                # common snapshot, it may be newer than "X" and there
                                                # might be no common snapshots older than "X" - then
                                                # we would have to roll back to replicate from scratch.
                                                last if defined($seenX); # lastCommon is same or older than X
                                                last if ($self->forbidDestRollback && !($backupSet->{"dst_$key" . '_justCreated'})); # not asked to/can't roll back anyway... well we're unlikely to see snaps in a justCreated destination as well
                                                $self->zLog->debug("sendRecvCleanup() [--since mode]: found a newest common snapshot between $srcDataSet and $dstDataSet is '$lastCommon' that matches --since='" . $self->since . "', but have not seen a --sinceForced='" . $self->since . "' match so keep looking where we can roll back to");
                                            }
                                            last if defined($seenX); # firstCommon is same or older than X
                                        }
                                    }

                                    if ($i < 0) {
                                        $self->zLog->debug("sendRecvCleanup() [--since mode]: looked through all snapshots of $srcDataSet;"
                                            . " seenX=" . (defined($seenX) ? $seenX : "undef")
                                            . " seenD=" . (defined($seenD) ? $seenD : "undef")
                                            . " lastCommonNum=" . (defined($lastCommonNum) ? $lastCommonNum : "undef")
                                            . " lastCommon=" . (defined($lastCommon) ? $lastCommon : "undef")
                                            . " firstCommonNum=" . (defined($firstCommonNum) ? $firstCommonNum : "undef")
                                            . " firstCommon=" . (defined($firstCommon) ? $firstCommon : "undef")
                                            ) if $self->debug;
                                    }

                                    # Flag for whether we should run an extra sendRecvSnapshots()
                                    # to get the "X" snapshot into history of destination.
                                    # A value of 2 enforces this, allowing to destroy snapshots
                                    # on destination to allow repopulation of that dataset with
                                    # new history if user said --sinceForced=X
                                    my $doPromote = 0;
                                    if (defined($seenD)) {
                                        # if seenD - skip the below decisions; note it also means seenX and that "X" is among common snapshots
                                        $self->zLog->debug("sendRecvCleanup() [--since mode]: A common snapshot between $srcDataSet and $dstDataSet that already matches --since='" . $self->since . "' is '${$srcSnapshots}[$seenX]'");
                                    } else {
                                        if (defined($lastCommon)) { # also means defined firstCommon
                        # 3) "X" in src is newer than the newest common snapshot
                        #    or "X" exists in src and there is NO common snapshot
                        #    => promote it into dst explicitly if we skipIntermediates
                        #       and proceed to resync starting from "X" afterwards
                        #       (if we do not skipIntermediates then no-op -
                        #       it will be included in replication below from
                        #       that older common point anyway)
                                            if (defined($seenX)) {
                                                # Note: the value of a defined seenX is a number of
                                                # that snapshot in our list, so may validly be zero
                                                if ($self->skipIntermediates) {
                                                    if (defined($lastCommon) && $lastCommon ne '') {
                                                        if ($lastCommonNum == $seenX || $lastCommon =~ m/\@$self->since$/ ) {
                                                            $self->zLog->debug("sendRecvCleanup() [--since mode]: Newest common snapshot between $srcDataSet and $dstDataSet is '$lastCommon' and already matches --since='" . $self->since . "'");
                                                        } else {
                                                            if ($lastCommonNum < $seenX) {
                                                                $self->zLog->debug("sendRecvCleanup() [--since mode]: Newest common snapshot between $srcDataSet and $dstDataSet is '$lastCommon' and older than a --since='" . $self->since . "' match (${$srcSnapshots}[$seenX])");
                                                                $doPromote = 1;
                                                            } else {
                                                                if (!$self->forbidDestRollback) { # || ($backupSet->{"dst_$key" . '_justCreated'})) {
                                                                    $self->zLog->debug("sendRecvCleanup() [--since mode]: Newest common snapshot between $srcDataSet and $dstDataSet is '$lastCommon' and newer than a --sinceForced='" . $self->since . "' match (${$srcSnapshots}[$seenX]), should try to roll back and resync from that");
                                                                    $doPromote = 2;
                                                                } else {
                                                                    $self->zLog->debug("sendRecvCleanup() [--since mode]: Newest common snapshot between $srcDataSet and $dstDataSet is '$lastCommon' and newer than a --since='" . $self->since . "' match (${$srcSnapshots}[$seenX]), but rollback of dest is forbidden");
                                                                }
                                                            }
                                                        }
                                                    } else {
                                                        if ( (scalar @$dstSnapshots) > 0) {
                                                            if ($self->forbidDestRollback && !($backupSet->{"dst_$key" . '_justCreated'})) {
                                                                $self->zLog->debug("sendRecvCleanup() [--since mode]: There is no common snapshot between $srcDataSet and $dstDataSet to compare with a --since='" . $self->since . "' match, but rollback of dest is forbidden");
                                                            } else {
                                                                $self->zLog->debug("sendRecvCleanup() [--since mode]: There is no common snapshot between $srcDataSet and $dstDataSet to compare with a --since='" . $self->since . "' match, should try resync from scratch");
                                                                $doPromote = 2;
                                                            }
                                                        } else {
                                                            $self->zLog->debug("sendRecvCleanup() [--since mode]: There is no common snapshot between $srcDataSet and $dstDataSet to compare with a --since='" . $self->since . "' match, because there are no snapshots in dst, should try resync from scratch");
                                                            $doPromote = 2;
                                                        }
                                                    }
                                                } else {
                                                    # if (seenX && !skipIntermediates) :
                                                    $self->zLog->debug("sendRecvCleanup() [--since mode]: Newest common snapshot between $srcDataSet and $dstDataSet is '$lastCommon' and older than a --since='" . $self->since . "' match (${$srcSnapshots}[$seenX]), but we would send a complete replication stream with all intermediates below anyway");
                                                }
                                            } # // 3. if seenX

                        # 4) "X" in src is older than the newest common snapshot
                        #    => promote it into dst explicitly ONLY IF WE DO NOT
                        #       forbidDestRollback (deleting whatever is newer
                        #       on dst) and proceed to resync starting from "X"
                        #       afterwards (if we forbidDestRollback honor that)
                                            if (!defined($seenX)) {
                                            # Did not see "X" as we went through history of SRC
                                            # Either it is not there (should not happen here per
                                            # checks done above), or is older than the newest
                                            # common snapshot and we did not intend to roll back
                                                if (!$self->forbidDestRollback || ($backupSet->{"dst_$key" . '_justCreated'})) {
                                                    # We should have looked through whole SRC
                                                    # history to get here. And not seenX. Fishy!
                                                    if ($firstCommonNum == $lastCommonNum) {
                                                        $self->zLog->debug("sendRecvCleanup() [--since mode]: The newest (and oldest) common snapshot between $srcDataSet and $dstDataSet is '$lastCommon' and there is no --sinceForced='" . $self->since . "' match in destination, would try to resync from previous common point or from scratch");
                                                        $doPromote = 2;
                                                    } else {
                                                        $self->zLog->debug("sendRecvCleanup() [--since mode]: The newest common snapshot between $srcDataSet and $dstDataSet is '$lastCommon', and the oldest is '$firstCommon', and there is no --sinceForced='" . $self->since . "' match in destination, would try to resync from previous common point or from scratch");
                                                        $doPromote = 2;
                                                    }
                                                } else {
                                                    $self->zLog->debug("sendRecvCleanup() [--since mode]: Newest common snapshot between $srcDataSet and $dstDataSet is '$lastCommon' and newer than a --since='" . $self->since . "' match (if any), but we forbidDestRollback so will not ensure it appears on destination");
                                                }
                                            } # // 4. if !seenX => "X" is too old or absent

                                        } else { ### =>  if (!defined($lastCommon)) ...
                        # 5) There may be no common snapshot at all.
                        # There may be no snapshots on destination at all.
                        # Destination may be "justCreated" and/or a value
                        # for forbidDestRollback==false can permit us to
                        # rewrite any contents of that destination (live
                        # data or existing "unneeded" snapshots).
                                            if (scalar(@$dstSnapshots) > 0) {
                                                if (!$self->forbidDestRollback) { # || ($backupSet->{"dst_$key" . '_justCreated'})) {
                        # 5b) There are discardable snapshots on destination...
                                                    $self->zLog->debug("sendRecvCleanup() [--since mode]: There is no common snapshot between $srcDataSet and $dstDataSet, and we may roll it back");
                                                    $doPromote = 2;
                                                } else {
                                                    $self->zLog->debug("sendRecvCleanup() [--since mode]: There is no common snapshot between $srcDataSet and $dstDataSet, but we may not roll it back");
                                                }
                                            } else {
                        # 5a) There are no snapshots on destination...
                                            # TODO: Find a way to state that destination is empty
                                            # de-facto (e.g. created last run) and can be rolled
                                            # back without loss of data because there are none...
                                                if (!$self->forbidDestRollback || ($backupSet->{"dst_$key" . '_justCreated'})) {
                                                    $self->zLog->debug("sendRecvCleanup() [--since mode]: There are no snapshots on destination $dstDataSet, and we may roll it back");
                                                    $doPromote = 1;
                                                } else {
                                                    $self->zLog->debug("sendRecvCleanup() [--since mode]: There are no snapshots on destination $dstDataSet, but we may not roll it back");
                                                }
                                            } # // 5a. No dest snaps at all
                                        } # // 5. No common snapshots at all
                                    } # // seenD => "X" is a common snapshot already

                                    if ($doPromote > 0) {
                                        $self->zLog->debug("sendRecvCleanup() [--since mode]: Making sure that snapshot '" . $self->since . "' exists in history of '$dstDataSet' ...");
                                        my $lastSnapshotToSee = $self->since;
                                        if (defined($seenX)) {
                                            $lastSnapshotToSee = ${$srcSnapshots}[$seenX];
                                        }
                                        $self->zZfs->sendRecvSnapshots($srcDataSet, $dstDataSet, $dst,
                                                $backupSet->{mbuffer}, $backupSet->{mbuffer_size},
                                                $backupSet->{snapSendFilter}, $lastSnapshotToSee,
                                                ( $backupSet->{"dst_$key" . '_justCreated'} ? 1 : ($doPromote > 1 ? $doPromote : undef ) )
                                            );
                                    } else {
                                        $self->zLog->debug("sendRecvCleanup() [--since mode]: We considered --since='" . $self->since . "' and did not find reasons to use sendRecvSnapshots() explicitly to make it appear in $dstDataSet");
                                    }
                                } else {
                                    $self->zLog->debug("sendRecvCleanup() [--since mode]: Got an empty list, does source dataset $srcDataSet have any snapshots?");
                                } # if not scalar - no src snaps?
                            } else {
                                $self->zLog->debug("sendRecvCleanup() [--since mode]: Destination dataset $dstDataSet already has a snapshot named by --since='" . $self->since . "'");
                            } # // 2. if dst has "X"
                        } else {
                            $self->zLog->debug("sendRecvCleanup() [--since mode]: Source dataset $srcDataSet does not have a snapshot named by --since='" . $self->since . "'");
                            if (!$self->forbidDestRollback) { # || ($backupSet->{"dst_$key" . '_justCreated'})) {
                                die "User required --sinceForced='" . $self->since . "' but there is no match in source dataset $srcDataSet";
                            }
                        } # // 1. if src does not have "X"
                    } # if have to care about "--since=X"

                    # Synchronize snapshot history from source to destination
                    # starting from newest snapshot that they have in common
                    # (or create/rewrite destination if it has no snapshots).
                    # With "--since=X" option handled above, such newest common
                    # snapshot can likely be this "X".
                    # Note this can fail if we forbidDestRollback and there are
                    # snapshots or data on dst newer than the last common snap.
                    $self->zZfs->sendRecvSnapshots($srcDataSet, $dstDataSet, $dst,
                        $backupSet->{mbuffer}, $backupSet->{mbuffer_size},
                        $backupSet->{snapSendFilter}, undef,
                        ( $backupSet->{"dst_$key" . '_justCreated'} ? 1 : undef )
                        );
                };
                if (my $err = $@){
                    $thisSendFailed = 1;
                    if (blessed $err && $err->isa('Mojo::Exception')){
                        $self->zLog->warn($err->message);
                        push (@sendFailed, $err->message);
                    }
                    else{
                        $self->zLog->warn($err);
                        push (@sendFailed, $err);
                    }
                }
            }
        }

        # do not destroy data sets on the destination, or run post-send-command, unless all operations have been successful
        next if ($thisSendFailed);

        # Remember which snapnames we already decided about in first phase
        # (recursive cleanup from top backupSet-dst) if we did run it indeed.
        # Do so with hash array for faster lookups into snapname existence.
        my %snapnamesRecursive = ();

        #cleanup current destination
        if ($backupSet->{recursive} eq 'on') {
            # First we try to recursively (and atomically quickly)
            # remove snapshots of "root" dataset with the recursive
            # configuration; then go looking for leftovers if any.
            # On many distros, ZFS has some atomicity lock for pool
            # operations - so one destroy operation takes ages...
            # but hundreds of queued operations take the same time
            # and are all committed at once.
            @snapshots = @{$self->zZfs->listSnapshots($backupSet->{$dst}, $backupSet->{snapCleanFilter})};
            $toDestroy = $self->zTime->getSnapshotsToDestroy(\@snapshots,
                         $backupSet->{"dst$key" . 'PlanHash'}, $backupSet->{tsformat}, $timeStamp, $self->since);

            # Save the names we have seen, to not revisit them below for children
            for (@{$self->zZfs->extractSnapshotNames(\@snapshots)}) {
                $snapnamesRecursive{$_} = 1;
            }
            # Note to devs: move extractSnapshotNames(toDestroy) up here
            # if you would introduce logic that cleans that array.

            if (scalar($toDestroy) == 0) {
                $self->zLog->debug('got an empty toDestroy list for cleaning up destination snapshots recursively under ' . $backupSet->{dst});
            } else {
                # Note to devs: Unlike code for sources, here we only extract
                # snapnames when we know the @toDestroy array is not empty -
                # and it was not cleaned by any (missing) logic above.
                for (@{$self->zZfs->extractSnapshotNames(\@{$toDestroy})}) {
                    $snapnamesRecursive{$_} = 2;
                }

                $self->zLog->debug('cleaning up snapshots recursively under destination ' . $backupSet->{$dst});
                $self->zLog->debug(Dumper(\@{$toDestroy})) if $self->debug;
                {
                    local $@;
                    eval {
                        local $SIG{__DIE__};
                        $self->zZfs->destroySnapshots($toDestroy, 1);
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
            }
            $self->zLog->debug('now will look if there is anything to clean in children of destination ' . $backupSet->{$dst});
        }

        #cleanup children of current destination
        for my $srcDataSet (@$srcSubDataSets){
            my $dstDataSet = $srcDataSet;
            $dstDataSet =~ s/^\Q$backupSet->{src}\E/$backupSet->{$dst}/;

            next if ($backupSet->{recursive} eq 'on' && $dstDataSet eq $backupSet->{$dst});

            # cleanup according to backup schedule
            @snapshots = @{$self->zZfs->listSnapshots($dstDataSet, $backupSet->{snapCleanFilter})};
            $toDestroy = $self->zTime->getSnapshotsToDestroy(\@snapshots,
                         $backupSet->{"dst$key" . 'PlanHash'}, $backupSet->{tsformat}, $timeStamp, $self->since);

            if (scalar(%snapnamesRecursive) && scalar(@{$toDestroy}) > 0) {
                for my $snapname (@{$self->zZfs->extractSnapshotNames(\@{$toDestroy})}) {
                    if ($snapnamesRecursive{$snapname}) {
                        $self->zLog->debug('not considering whether to clean destination ' . $dstDataSet . '@' . $snapname . ' as it was already processed in recursive mode') if $self->debug;
                        #print STDERR "DESTINATION CHILD UNCONSIDER CLEAN: BEFORE: " . Dumper($toDestroy) if $self->debug;
                        @{$toDestroy} = grep { ($dstDataSet . '@' . $snapname) ne $_ } @{$toDestroy};
                        #print STDERR "DESTINATION CHILD UNCONSIDER CLEAN: BEFORE: " . Dumper($toDestroy) if $self->debug;
                    }
                }
            }

            next if (scalar (@{$toDestroy}) == 0);

            $self->zLog->debug('cleaning up snapshots on destination ' . $dstDataSet);
            $self->zLog->debug(Dumper(\@{$toDestroy})) if $self->debug;
            {
                local $@;
                eval {
                    local $SIG{__DIE__};
                    $self->zZfs->destroySnapshots($toDestroy, 0);
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
        }

        #check destination for remote post-send-command
        if ($backupSet->{"dst_$key" . '_pstcmd'} && $backupSet->{"dst_$key" . '_pstcmd'} ne 'off'){
            local $ENV{WORKER} = $backupSet->{"dst_$key"};
            $self->zLog->info("running post-send-command for " . $backupSet->{"dst_$key"});

            system($backupSet->{"dst_$key" . '_pstcmd'})
                && $self->zLog->warn("command \'" . $backupSet->{"dst_$key" . '_pstcmd'} . "\' failed");
            delete $ENV{WORKER};
        }
    }

    #cleanup source
    #we want the message summarizing errors regardless of continuing to cleanup
    if (scalar(@sendFailed) > 0) {
        my $errmsg;
        my $errline;
        if ($self->cleanOffline) {
            # Note: this is about all transfer failures, such as offline dest
            # or it is full, or read-only, or source too full to make a snap...
            $errline = 'ERROR: ' . scalar(@sendFailed) . ' send task(s) below ' .
                'failed for ' . $backupSet->{src} . ', but "cleanOffline" mode ' .
                'is on, so proceeding to clean up source dataset carefully:' ;
        } else {
            $errline = 'ERROR: suspending cleanup source dataset ' .
                $backupSet->{src} . ' because ' .
                scalar(@sendFailed) . ' send task(s) failed:' ;
        }
        $self->zLog->warn($errline);
        if ($self->mailErrorSummaryTo) {
            $errmsg = $errline . "\n";
        }
        for $errline (@sendFailed) {
            $self->zLog->warn(' +-->   ' . $errline);
            if ($self->mailErrorSummaryTo) {
                $errmsg .= ' +-->   ' . $errline . "\n";
            }
        }

        if ($self->mailErrorSummaryTo) {
            #my $mailprog = '/usr/lib/sendmail';
            my $mailprog = '/usr/sbin/sendmail';
            #my $from_address = "`id`@`hostname`" ;
            if (open (MAIL, "|$mailprog -t " . $self->mailErrorSummaryTo)) {
                $self->zLog->warn('Sending a copy of the report above to ' . $self->mailErrorSummaryTo);
                print MAIL "To: " . $self->mailErrorSummaryTo . "\n";
                #print MAIL "From: " . $from_address . "\n";
                print MAIL "Subject: znapzend replication error summary\n";
                print MAIL "-------\n";
                print MAIL $errmsg;
                print MAIL "-------\n";
                print MAIL ".\n";
                close(MAIL);
            } else {
                warn "Can't open $mailprog to send a copy of the report above to " . $self->mailErrorSummaryTo . "!\n";
            }
        }
    }

    if (scalar(@sendFailed) == 0 or $self->cleanOffline) {
        # If "not sendFailed" or "cleanOffline requested"...
        # cleanup source according to backup schedule

        # Remember which snapnames we already decided about in first phase
        # (recursive cleanup from top backupSet-src) if we did run it indeed.
        # Do so with hash array for faster lookups into snapname existence.
        my %snapnamesRecursive = ();

        if ($backupSet->{recursive} eq 'on') {
            # First we try to recursively (and atomically quickly)
            # remove snapshots of "root" dataset with the recursive
            # configuration; then go looking for leftovers if any.
            # On many distros, ZFS has some atomicity lock for pool
            # operations - so one destroy operation takes ages...
            # but hundreds of queued operations take the same time
            # and are all committed at once.
            $self->zLog->debug('checking to clean up snapshots recursively from source '. $backupSet->{src});

            @snapshots = @{$self->zZfs->listSnapshots($backupSet->{src}, $backupSet->{snapCleanFilter})};
            $toDestroy = $self->zTime->getSnapshotsToDestroy(\@snapshots,
                         $backupSet->{srcPlanHash}, $backupSet->{tsformat}, $timeStamp, $self->since);

            # Save the names we have seen, to not revisit them below for children
            for (@{$self->zZfs->extractSnapshotNames(\@snapshots)}) {
                $snapnamesRecursive{$_} = 1;
            }
            for (@{$self->zZfs->extractSnapshotNames(\@{$toDestroy})}) {
                $snapnamesRecursive{$_} = 2;
            }

            # preserve most recent common snapshots for each destination
            # (including offline destinations for which last-known sync
            # snapshot name is saved in properties of the source policy)
            my $doClean = 1;

            if (scalar($toDestroy) > 0) {
                # Check if any death-rowed snapshots need protection
                for my $dst (sort grep { /^dst_[^_]+$/ } keys %$backupSet){
                    my $dstDataSet = $backupSet->{src};
                    $dstDataSet =~ s/^\Q$backupSet->{src}\E/$backupSet->{$dst}/;
                    my $recentCommon = $self->zZfs->mostRecentCommonSnapshot($backupSet->{src}, $dstDataSet, $dst, $backupSet->{snapCleanFilter}, ($backupSet->{recursive} eq 'on'), undef );
                    if ($recentCommon) {
                        $self->zLog->debug('not cleaning up source ' . $recentCommon . ' recursively because it is needed by ' . $dstDataSet) if $self->debug;
                        #print STDERR "SOURCE RECURSIVE CLEAN: BEFORE: " . Dumper($toDestroy) if $self->debug;
                        @{$toDestroy} = grep { $recentCommon ne $_ } @{$toDestroy};
                        #print STDERR "SOURCE RECURSIVE CLEAN: AFTER: " . Dumper($toDestroy) if $self->debug;
                    } elsif (scalar(@sendFailed) > 0) {
                        # If we are here, "--cleanOffline" was requested,
                        # and at least one destination is indeed offline,
                        # but it is not safe in current situation regarding
                        # last known sync points...
                        # Note this includes a case where source dataset has
                        # NO snapshots (message is misleading but true then).
                        # This should not happen in normal runs since znapzend
                        # would create something, but can happen in --noaction
                        # experiments for example.
                        $self->zLog->warn('ERROR: suspending recursive cleanup of source ' . $backupSet->{src} . ' because a send task failed and no common snapshot was found for at least destination ' . $dstDataSet);
                        $doClean = 0;
                    }
                }
            }

            if (scalar($toDestroy) == 0) {
                $self->zLog->debug('got an empty toDestroy list for cleaning up source snapshots recursively under ' . $backupSet->{src});
                $doClean = 0;
            }

            if ($doClean) {
                $self->zLog->debug('cleaning up ' . scalar (@{$toDestroy}) . ' source snapshots recursively under ' . $backupSet->{src});
                $self->zLog->debug(Dumper(\@{$toDestroy})) if $self->debug;
                {
                    local $@;
                    eval {
                        local $SIG{__DIE__};
                        $self->zZfs->destroySnapshots($toDestroy, 1);
                    };
                    if ($@){
                        if (blessed $@ && $@->isa('Mojo::Exception')){
                            $self->zLog->warn($@->message);
                        }
                        else{
                            $self->zLog->warn($@);
                        }
                    }
                } # scope
            } else {
                $self->zLog->debug('NOT cleaning up source snapshots recursively under ' . $backupSet->{src});
            }
            $self->zLog->debug('now will look if there is anything to clean in children of source ' . $backupSet->{src});
        }

        # See if there is anything remaining to clean up in child
        # datasets (if recursive snapshots are enabled) or just
        # this one dataset.
        # Note: we apply reverse sorting by dataset names, so any
        # "custom" child dataset snapshots (made with --inherited
        # mode starting from mid-tree) are deleted first, parents
        # last, and we do not lose track of mostRecentCommonSnapshot
        # if we have to iterate up to root to find dst_X_synced.
        SRC_SET:
        for my $srcDataSet (sort {$b cmp $a} @$srcSubDataSets){
            next if ($backupSet->{recursive} eq 'on' && $srcDataSet eq $backupSet->{src});

            $self->zLog->debug('checking to clean up snapshots of source '. $srcDataSet);

            @snapshots = @{$self->zZfs->listSnapshots($srcDataSet, $backupSet->{snapCleanFilter})};
            $toDestroy = $self->zTime->getSnapshotsToDestroy(\@snapshots,
                         $backupSet->{srcPlanHash}, $backupSet->{tsformat}, $timeStamp, $self->since);

            if (scalar(%snapnamesRecursive) && scalar(@{$toDestroy}) > 0) {
                for my $snapname (@{$self->zZfs->extractSnapshotNames(\@{$toDestroy})}) {
                    if ($snapnamesRecursive{$snapname}) {
                        $self->zLog->debug('not considering whether to clean source ' . $srcDataSet . '@' . $snapname . ' as it was already processed in recursive mode') if $self->debug;
                        #print STDERR "SOURCE CHILD UNCONSIDER CLEAN: BEFORE: " . Dumper($toDestroy) if $self->debug;
                        @{$toDestroy} = grep { ($srcDataSet . '@' . $snapname) ne $_ } @{$toDestroy};
                        #print STDERR "SOURCE CHILD UNCONSIDER CLEAN: BEFORE: " . Dumper($toDestroy) if $self->debug;
                    }
                }
            }

            # preserve most recent common snapshots for each destination
            # (including offline destinations for which last-known sync
            # snapshot name is saved in properties of the source policy)
            for my $dst (sort grep { /^dst_[^_]+$/ } keys %$backupSet){
                my $dstDataSet = $srcDataSet;
                $dstDataSet =~ s/^\Q$backupSet->{src}\E/$backupSet->{$dst}/;
                my $recentCommon = $self->zZfs->mostRecentCommonSnapshot($srcDataSet, $dstDataSet, $dst, $backupSet->{snapCleanFilter}, undef, undef);
                if ($recentCommon) {
                    $self->zLog->debug('not cleaning up source ' . $recentCommon . ' because it is needed by ' . $dstDataSet) if $self->debug;
                    #print STDERR "SOURCE CHILD CLEAN: BEFORE: " . Dumper($toDestroy) if $self->debug;
                    @{$toDestroy} = grep { $recentCommon ne $_ } @{$toDestroy};
                    #print STDERR "SOURCE CHILD CLEAN: AFTER: " . Dumper($toDestroy) if $self->debug;
                } elsif (scalar(@sendFailed) > 0) {
                    # If we are here, "--cleanOffline" was requested,
                    # and at least one destination is indeed offline,
                    # but it is not safe in current situation regarding
                    # last known sync points...
                    # Note this includes a case where source dataset has
                    # NO snapshots (message is misleading but true then).
                    # This should not happen in normal runs since znapzend
                    # would create something, but can happen in --noaction
                    # experiments for example.
                    $self->zLog->warn('ERROR: suspending cleanup of source ' . $srcDataSet . ' because a send task failed and no common snapshot was found for at least destination ' . $dstDataSet);
                    next SRC_SET;
                }
            }

            if (scalar (@{$toDestroy}) == 0) {
                $self->zLog->debug('got nothing to clean in source ' . $srcDataSet);
                next;
            }

            $self->zLog->debug('cleaning up ' . scalar (@{$toDestroy}) . ' snapshots on source ' . $srcDataSet);
            $self->zLog->debug(Dumper(\@{$toDestroy})) if $self->debug;
            {
                local $@;
                eval {
                    local $SIG{__DIE__};
                    $self->zZfs->destroySnapshots($toDestroy, 0);
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
        }
    }
    $self->zLog->info('done with backupset ' . $backupSet->{src} . ' in '
        . (time - $startTime) . ' seconds');

    return 1;
};

my $createSnapshot = sub {
    my $self = shift;
    my $backupSet = shift;
    my $timeStamp = shift;

    #no HUP handler in child
    $SIG{HUP} = 'IGNORE';

    my $snapshotSuffix;
    if (defined($self->forcedSnapshotSuffix) && $self->forcedSnapshotSuffix ne '') {
        $self->zLog->warn("requesting manually specified snapshot suffix '@" . $self->forcedSnapshotSuffix ."'");
        $snapshotSuffix = $self->forcedSnapshotSuffix;
    } else {
        $snapshotSuffix = $self->zTime->createSnapshotTime($timeStamp, $backupSet->{tsformat});
    }
    # Basic sanity/security check (e.g. don't let the user pass extra
    # keywords to zfs cli using bad forcedSnapshotSuffix option or
    # backup plan config patterns)
    if ($snapshotSuffix =~ /[@\s\"\'\`#\$]/) { ### # ` and $ to try and avoid shell escaping
        die ("snapshot suffix '$snapshotSuffix' contains invalid characters\n");
    }

    my $snapshotName = $backupSet->{src} . '@'. $snapshotSuffix;

    #set env variables for pre and post scripts use
    local $ENV{ZNAP_NAME} = $snapshotName;
    local $ENV{ZNAP_TIME} = $timeStamp;

    my $skip = 0;

    if ($backupSet->{pre_znap_cmd} && $backupSet->{pre_znap_cmd} ne 'off'){
        $self->zLog->info("running pre snapshot command on $backupSet->{src}");

        if (system($backupSet->{pre_znap_cmd})){
            $self->zLog->warn("running pre snapshot command on $backupSet->{src} failed");

            if ($self->skipOnPreSnapCmdFail){
                $self->zLog->warn("skipping snapshot on $backupSet->{src}" .
                    " due to pre snapshot command failure");
                $skip = 1;
            }
        }
    }

    if (!$skip){
        $self->zLog->info('creating ' . ($backupSet->{recursive} eq 'on' ? 'recursive ' : '')
            . 'snapshot on ' . $backupSet->{src});

        $self->zZfs->createSnapshot($snapshotName, $backupSet->{recursive} eq 'on')
            or $self->zLog->info("snapshot '$snapshotName' does already exist. skipping one round...");

        if ($backupSet->{post_znap_cmd} && $backupSet->{post_znap_cmd} ne 'off'){
            $self->zLog->info("running post snapshot command on $backupSet->{src}");

            system($backupSet->{post_znap_cmd})
                && $self->zLog->warn("running post snapshot command on $backupSet->{src} failed");
        }
    }

    # Remove snapshots from descendant subsystems that have the property
    # "enabled" set to "off", if the "recursive" flag is set to "on",
    # so their newly created snapshots are discarded quickly and disk
    # space is not abused by something we do not back up subsequently.
    # This only applies if we made a single-command recursive snapshot.
    if ($backupSet->{recursive} eq 'on') {

        $self->zLog->info("checking for explicitly excluded ZFS dependent datasets under '$backupSet->{src}'");

        # restrict the list to the datasets that are descendant from the current
        ###my @dataSetList = grep /^$backupSet->{src}($|\/)/, @{$self->zZfs->listDataSets()};
        my @dataSetList = @{$self->zZfs->listDataSets(undef, $backupSet->{src}, 1)};
        if ( @dataSetList ) {

            # for each dataset: if the property "enabled" is set to "off", set the
            # newly created snapshot for removal
            my @dataSetsExplicitlyDisabled = ();
            for my $dataSet (@dataSetList){

                # get the value for org.znapzend property
                my @cmd = (@{$self->zZfs->priv}, qw(zfs get -H -s local -o value org.znapzend:enabled), $dataSet);
                print STDERR '# ' . join(' ', @cmd) . "\n" if $self->debug;
                open my $prop, '-|', @cmd;

                # if the property does not exist, the command will just return. In this case,
                # the value is implicit "on"
                $prop = <$prop> || "on";
                chomp($prop);
                if ( $prop eq 'off' ) {
                    push(@dataSetsExplicitlyDisabled, $dataSet . '@' . $snapshotSuffix);
                }
            }

            # remove the snapshots previously marked
            # removal here is non-recursive to allow for fine-grained control
            if ( @dataSetsExplicitlyDisabled ){
               $self->zLog->info("Requesting removal of marked datasets: ". join( ", ", @dataSetsExplicitlyDisabled));
               $self->zZfs->destroySnapshots(@dataSetsExplicitlyDisabled, 0);
           }
        }
    }

    #clean up env variables
    delete $ENV{ZNAP_NAME};
    delete $ENV{ZNAP_TIME};

    return 1;
};

my $sendWorker = sub {
    my $self = shift;
    my $backupSet = shift;
    my $timeStamp = shift;

### RM_COMM_4_TEST ###  # remove ### RM_COMM_4_TEST ### comments for testing purpose.
### RM_COMM_4_TEST ###  $self->$sendRecvCleanup($backupSet, $timeStamp);
### RM_COMM_4_TEST ###  return;

    #send/receive fork
    my $fc = Mojo::IOLoop::ForkCall->new;
    $fc->run(
        #send/receive worker
        $sendRecvCleanup,
        #send/receive worker arguments
        [$self, $backupSet, $timeStamp],
        #send/receive worker callback
        sub {
            my ($fc, $err) = @_;

            $self->zLog->warn('send/receive for ' . $backupSet->{src}
                . ' failed: ' . $err) if $err;

            $self->zLog->debug('send/receive worker for ' . $backupSet->{src}
                . " done ($backupSet->{send_pid})");
            #send/receive process finished, clear pid from backup set
            $backupSet->{send_pid} = 0;
        }
    );

    #spawn event
    $fc->on(
        spawn => sub {
            my ($fc, $pid) = @_;
            $backupSet->{send_pid} = $pid;
            $self->zLog->debug('send/receive worker for ' . $backupSet->{src}
                . " spawned ($pid)");
        }
    );

    #error event
    $fc->on(
        error => sub {
            my ($fc, $err) = @_;
            $self->zLog->warn($err) if !$self->terminate;
        }
    );
};

my $snapWorker = sub {
    my $self = shift;
    my $backupSet = shift;
    my $timeStamp = shift;

### RM_COMM_4_TEST ###  # remove ### RM_COMM_4_TEST ### comments for testing purpose.
### RM_COMM_4_TEST ###  $self->$createSnapshot($backupSet, $timeStamp);
### RM_COMM_4_TEST ###  $self->$sendWorker($backupSet, $timeStamp);
### RM_COMM_4_TEST ###  return;

    #snapshot fork
    my $fc = Mojo::IOLoop::ForkCall->new;
    $fc->run(
        #snapshot worker
        $createSnapshot,
        #snapshot worker arguments
        [$self, $backupSet, $timeStamp],
        #snapshot worker callback
        sub {
            my ($fc, $err) = @_;

            $self->zLog->warn('taking snapshot on ' . $backupSet->{src}
                . ' failed: ' . $err) if $err;

            $self->zLog->debug('snapshot worker for ' . $backupSet->{src}
                . " done ($backupSet->{snap_pid})");
            
            if ($backupSet->{send_pid}){
                $self->zLog->info('previous send/receive process on ' . $backupSet->{src}
                    . ' still running! skipping this round...');
            }
            else{
                # Assign a temporary non-zero value to avoid race condition
                $backupSet->{send_pid} = ~0;
                $self->$sendWorker($backupSet, $timeStamp);
            }

            #snapshot process finished, clear pid from backup set
            $backupSet->{snap_pid} = 0;
        }
    );

    #spawn event
    $fc->on(
        spawn => sub {
            my ($fc, $pid) = @_;
            $backupSet->{snap_pid} = $pid;
            $self->zLog->debug('snapshot worker for ' . $backupSet->{src}
                . " spawned ($pid)");
        }
    );

    #error event
    $fc->on(
        error => sub {
            my ($fc, $err) = @_;
            $self->zLog->warn($err) if !$self->terminate;
        }
    );
};

my $createWorkers = sub {
    my $self = shift;

    #create a timer for each backup set
    for my $backupSet (@{$self->backupSets}){
        #calculate next snapshot timestamp
        my $timeStamp = $self->zTime->getNextSnapshotTimestamp($backupSet->{interval}, $backupSet->{UTC});
        #define timer callback
        my $cb;
        $cb = sub {
            #check if we run too early (can be caused by DST time 'jump')
            my $timeDelta = $timeStamp - $self->zTime->getTimestamp($backupSet->{UTC});
            if ($timeDelta > 0){
                $backupSet->{timer_id} = Mojo::IOLoop->timer($timeDelta => $cb);
                return;
            }

            if ($backupSet->{snap_pid}){
                $self->zLog->warn('last snapshot process still running! it seems your pre or '
                    . 'post snapshot script runs for ages. snapshot will not be taken this time!');
            }
            else{
                # Assign a temporary non-zero value to avoid race condition
                $backupSet->{snap_pid} = ~0;
                $self->$snapWorker($backupSet, $timeStamp);
            }

### RM_COMM_4_TEST ###  # remove ### RM_COMM_4_TEST ### comments for testing purpose.
### RM_COMM_4_TEST ###  return;

            #get next timestamp when a snapshot has to be taken
            $timeStamp = $self->zTime->getNextSnapshotTimestamp($backupSet->{interval}, $backupSet->{UTC});

            #reset timer for next snapshot if not runonce
            $backupSet->{timer_id} = Mojo::IOLoop->timer($timeStamp
                - $self->zTime->getTimestamp($backupSet->{UTC}) => $cb) if !$self->runonce;
        };

        #set timer for next snapshot or run immediately if runonce
        if ($self->runonce){
            #run immediately
            $timeStamp = $self->zTime->getTimestamp($backupSet->{UTC});
            $cb->();
        }
        else{
            $backupSet->{timer_id} = Mojo::IOLoop->timer($timeStamp
                - $self->zTime->getTimestamp($backupSet->{UTC}) => $cb);
        }
    };

};

my $daemonize = sub {
    my $self = shift;
    my $pidFile = $self->pidfile || $self->defaultPidFile;

    if (-f $pidFile){
        open my $fh, $pidFile or die "ERROR: pid file '$pidFile' exists but is not readable\n";
        chomp(my $pid = <$fh>);
        close $fh;
        #pid is not empty and is numeric, and is running
        if ($pid && ($pid = int($pid)) && (1 == kill 0, $pid) ){
### RM_COMM_4_TEST ###  # remove ### RM_COMM_4_TEST ### comments for testing purpose.
### RM_COMM_4_TEST ###  print STDERR "die: I Quit! Another copy of znapzend ($pid) seems to be running. See $pidFile\n"
### RM_COMM_4_TEST ###             . "die: znapzend ($$) returning not exiting from parent process during test.\n";
### RM_COMM_4_TEST ###  return 255;
            die "I Quit! Another copy of znapzend ($pid) seems to be running. See $pidFile\n";
        }
    }
    #make sure pid file is writable before forking
    open my $fh, '>', $pidFile or die "ERROR: pid file '$pidFile' is not writable\n";
    close $fh;

    defined (my $pid = fork) or die "Can't fork: $!";

    if ($pid){

### RM_COMM_4_TEST ###  # remove ### RM_COMM_4_TEST ### comments for testing purpose.
### RM_COMM_4_TEST ###  print STDERR "fork: znapzend ($$) returning not exiting from parent process during test.\n";
### RM_COMM_4_TEST ###  eval { if (defined(\@main::test_arr_children)) { print STDERR "PUSH!\n" ; push (@main::test_arr_children, $pid); }; };
### RM_COMM_4_TEST ###  return 254;

        #print STDERR "fork: znapzend ($$) exiting from parent process.\n";

        exit;
    }
    else{
        print STDERR "znapzend ($$) is running in the background now.\n";

        if ($pidFile){
            if (open my $fh, '>', $pidFile){
                print $fh "$$\n";
            }
            else {
                warn "creating pid file $pidFile: $!\n";
            }
        }
        setsid or die "Can't start a new session: $!";

        open STDIN, '</dev/null' or die "ERROR: Redirecting STDIN from /dev/null: $!";
### RM_COMM_4_TEST ###  # remove ### RM_COMM_4_TEST ### comments for testing purpose.
### RM_COMM_4_TEST ###  if (0) {
        open STDOUT, '>/dev/null' or die "ERROR: Redirecting STDOUT to /dev/null: $!";
        open STDERR, '>/dev/null' or die "ERROR: Redirecting STDERR to /dev/null: $!";
### RM_COMM_4_TEST ###  }

        # send warnings and die messages to log
        $SIG{__WARN__} = sub { $self->zLog->warn(shift) };
        $SIG{__DIE__}  = sub { return if $^S; $self->zLog->error(shift); exit 1 };

    }
    return 1;
};

### public methods ###
sub start {
    my $self = shift;
    my $ready_to_refresh = 1;

    $self->zLog->info("znapzend (PID=$$) starting up ...");

    if ($self->daemonize) {
        my $resDaemonize = $self->$daemonize;
### RM_COMM_4_TEST ###  # remove ### RM_COMM_4_TEST ### comments for testing purpose.
### RM_COMM_4_TEST ###  if ($resDaemonize == 255) { return 255; } # die on pidfile clash
### RM_COMM_4_TEST ###  if ($resDaemonize == 254) { return 254; } # parent exit
        if ($resDaemonize != 1) {
            die "znapzend ($$) failed to daemonize: $resDaemonize !";
        }
    }

    # set signal handlers
    $SIG{INT}  = sub { $self->zLog->debug('SIGINT received.'); $self->$killThemAll; };
    $SIG{TERM} = sub { $self->zLog->debug('SIGTERM received.'); $self->$killThemAll; };
    $SIG{HUP}  = sub {
        $self->zLog->debug('SIGHUP received.');

        #remove active timers from ioloop
        for my $backupSet (@{$self->backupSets}){
            Mojo::IOLoop->remove($backupSet->{timer_id}) if $backupSet->{timer_id};
        }

        if ($ready_to_refresh) {
            $ready_to_refresh = 0; # Exmut 

            $self->$refreshBackupPlans($self->recursive, $self->inherited, $self->dataset);
            $self->$createWorkers;

            $ready_to_refresh = 1;
        }

    };

    if ($ready_to_refresh) {
        $ready_to_refresh = 0; # Exmut
        print STDERR "znapzend (PID=$$) Refreshing backup plans...\n" if $self->debug;
        $self->$refreshBackupPlans($self->recursive, $self->inherited, $self->dataset);

        print STDERR "znapzend (PID=$$) Creating workers for the backup plans processing...\n" if $self->debug;
        $self->$createWorkers;
        $ready_to_refresh = 1;
    }

    $self->zLog->info("znapzend (PID=$$) initialized -- resuming normal operations.");

    # if Mojo is running with EV, signals will not be received if the IO loop
    # is sleeping so lets activate it periodically
### RM_COMM_4_TEST ###  # remove ### RM_COMM_4_TEST ### comments for testing purpose.
### RM_COMM_4_TEST ###  if (0) {
    Mojo::IOLoop->recurring(1 => sub { }) if not $self->runonce;
### RM_COMM_4_TEST ###  }

    #start eventloop
    Mojo::IOLoop->start;

    print STDERR "znapzend (PID=$$) is done.\n" if $self->debug;
    return 1;
}

1;

__END__

=head1 NAME

ZnapZend - znapzend main class

=head1 SYNOPSIS

use ZnapZend;
...
my $znapzend = ZnapZend->new(debug=>0, noaction=>0, nodestroy=>0);
...

=head1 DESCRIPTION

main znapzend class. does the scheduling and executes the necessary commands

=head1 ATTRIBUTES

=head2 debug

print debug information to STDERR

=head2 noaction

do a dry run. no changes to the filesystem will be performed

=head2 nodestroy

does all changes to the filesystem but no destroy

=head1 METHODS

=head2 start

starts znapzend backup process

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
S<Dominik Hassler E<lt>hadfl@cpan.orgE<gt>>

=head1 HISTORY

2016-09-23 ron Destination pre and post send/receive commands
2014-07-22 had Pre and post snapshot commands
2014-06-29 had Flexible snapshot time format
2014-06-10 had localtime implementation
2014-06-01 had Multi destination backup
2014-05-30 had Initial Version

=cut
