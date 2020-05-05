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
has noaction                => sub { 0 };
has nodestroy               => sub { 0 };
has oracleMode              => sub { 0 };
has recvu                   => sub { 0 };
has compressed              => sub { 0 };
has sendRaw                 => sub { 0 };
has skipIntermediates       => sub { 0 };
has lowmemRecurse           => sub { 0 };
has rootExec                => sub { q{} };
has zfsGetType              => sub { 0 };
has connectTimeout          => sub { 30 };
has runonce                 => sub { 0 };
has recursive               => sub { 0 };
has inherited               => sub { 0 };
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
        recvu => $self->recvu, connectTimeout => $self->connectTimeout,
        lowmemRecurse => $self->lowmemRecurse, skipIntermediates => $self->skipIntermediates,
        rootExec => $self->rootExec, zfsGetType => $self->zfsGetType,
        zLog => $self->zLog, compressed => $self->compressed,
        sendRaw => $self->sendRaw);
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

                    if ($self->autoCreation) {
                        my ($zpool) = $backupSet->{"dst_$key"} =~ /(^[^\/]+)\//;

                        # check if we can access destination zpool, if so create parent dataset
                        $self->zZfs->dataSetExists($zpool) && do {
                            $backupSet->{"dst_$key" . '_valid'} =
                                $self->zZfs->createDataSet($backupSet->{"dst_$key"});

                            $self->zLog->info("creating destination dataset '" . $backupSet->{"dst_$key"} . "'...");
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
        $backupSet->{snapCleanFilter} = $self->zTime->getSnapshotFilter($backupSet->{tsformat});
        # Due to support of possible intermediate snapshots named outside the
        # generated configured pattern (tsformat), to send (and not destroy on
        # destination) the arbitrary names, and find last common ones properly,
        # we should match all snap names here and there.
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
        warn "CLI option --nodelay was requested, so ignoring backup plan option 'zend-delay' (was $backupSet->{zend_delay}) on backupSet $backupSet->{src}";
        $backupSet->{zend_delay} = undef;
    }

    if (defined($backupSet->{zend_delay})) {
        chomp $backupSet->{zend_delay};
        if (!($backupSet->{zend_delay} =~ /^\d+$/)) {
            warn "Backup plan option 'zend-delay' has an invalid value ('$backupSet->{zend_delay}' is not a number) on backupSet $backupSet->{src}, ignored";
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

                if ($self->autoCreation) {
                    my ($zpool) = $backupSet->{"dst_$key"} =~ /(^[^\/]+)\//;

                    # check if we can access destination zpool, if so create parent dataset
                    $self->zZfs->dataSetExists($zpool) && do {
                        $backupSet->{"dst_$key" . '_valid'} =
                            $self->zZfs->createDataSet($backupSet->{"dst_$key"});

                        $self->zLog->info("creating destination dataset '" . $backupSet->{"dst_$key"} . "'...");
                    };
                }
                $backupSet->{"dst_$key" . '_valid'} or do {
                    my $errmsg = "destination '" . $backupSet->{"dst_$key"}
                        . "' does not exist or is offline. ignoring it for this round...";
                    $self->zLog->warn($errmsg);
                    push (@sendFailed, $errmsg);
                    $thisSendFailed = 1;
                };
                next;
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
                    $self->zZfs->sendRecvSnapshots($srcDataSet, $dstDataSet,
                        $backupSet->{mbuffer}, $backupSet->{mbuffer_size}, $backupSet->{snapSendFilter});
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
                         $backupSet->{"dst$key" . 'PlanHash'}, $backupSet->{tsformat}, $timeStamp);

            $self->zLog->debug('cleaning up snapshots recursively under ' . $backupSet->{$dst});
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
            $self->zLog->debug('now will look if there is anything to clean in children of ' . $backupSet->{$dst});
        }

        #cleanup children of current destination
        for my $srcDataSet (@$srcSubDataSets){
            my $dstDataSet = $srcDataSet;
            $dstDataSet =~ s/^\Q$backupSet->{src}\E/$backupSet->{$dst}/;

            next if ($backupSet->{recursive} eq 'on' && $dstDataSet eq $backupSet->{$dst});

            # cleanup according to backup schedule
            @snapshots = @{$self->zZfs->listSnapshots($dstDataSet, $backupSet->{snapCleanFilter})};
            $toDestroy = $self->zTime->getSnapshotsToDestroy(\@snapshots,
                         $backupSet->{"dst$key" . 'PlanHash'}, $backupSet->{tsformat}, $timeStamp);

            next if (scalar (@{$toDestroy}) == 0);

            $self->zLog->debug('cleaning up snapshots on ' . $dstDataSet);
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
    if (scalar(@sendFailed) > 0) {
        $self->zLog->warn('ERROR: suspending cleanup source dataset because '
            . scalar(@sendFailed) . ' send task(s) failed:');
        foreach my $errmsg (@sendFailed) {
            $self->zLog->warn(' +-->   ' . $errmsg);
        }
    }
    else{
        # cleanup source according to backup schedule
        if ($backupSet->{recursive} eq 'on') {
            # First we try to recursively (and atomically quickly)
            # remove snapshots of "root" dataset with the recursive
            # configuration; then go looking for leftovers if any.
            # On many distros, ZFS has some atomicity lock for pool
            # operations - so one destroy operation takes ages...
            # but hundreds of queued operations take the same time
            # and are all committed at once.

            @snapshots = @{$self->zZfs->listSnapshots($backupSet->{src}, $backupSet->{snapCleanFilter})};
            $toDestroy = $self->zTime->getSnapshotsToDestroy(\@snapshots,
                         $backupSet->{srcPlanHash}, $backupSet->{tsformat}, $timeStamp);

            $self->zLog->debug('cleaning up snapshots recursively under ' . $backupSet->{src});
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
            $self->zLog->debug('now will look if there is anything to clean in children of ' . $backupSet->{src});
        }

        # See if there is anything remaining to clean up in child
        # datasets (if recursive snapshots are enabled) or just
        # this one dataset.
        for my $srcDataSet (@$srcSubDataSets){
            next if ($backupSet->{recursive} eq 'on' && $srcDataSet eq $backupSet->{src});

            @snapshots = @{$self->zZfs->listSnapshots($srcDataSet, $backupSet->{snapCleanFilter})};
            $toDestroy = $self->zTime->getSnapshotsToDestroy(\@snapshots,
                         $backupSet->{srcPlanHash}, $backupSet->{tsformat}, $timeStamp);

            next if (scalar (@{$toDestroy}) == 0);

            $self->zLog->debug('cleaning up snapshots on ' . $srcDataSet);
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
        my @dataSetList = grep /^$backupSet->{src}($|\/)/, @{$self->zZfs->listDataSets()};
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

            $self->zLog->debug('send/receive worker for ' . $backupSet->{src}
                . " spawned ($pid)");
            $backupSet->{send_pid} = $pid;
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
            #snapshot process finished, clear pid from backup set
            $backupSet->{snap_pid} = 0;

            if ($backupSet->{send_pid}){
                $self->zLog->info('previous send/receive process on ' . $backupSet->{src}
                    . ' still running! skipping this round...');
            }
            else{
                $self->$sendWorker($backupSet, $timeStamp);
            }
        }
    );

    #spawn event
    $fc->on(
        spawn => sub {
            my ($fc, $pid) = @_;

            $self->zLog->debug('snapshot worker for ' . $backupSet->{src}
                . " spawned ($pid)");
            $backupSet->{snap_pid} = $pid;
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
        #pid is not empty and is numeric
        if ($pid && ($pid = int($pid)) && kill 0, $pid){
            die "I Quit! Another copy of znapzend ($pid) seems to be running. See $pidFile\n";
        }
    }
    #make sure pid file is writable before forking
    open my $fh, '>', $pidFile or die "ERROR: pid file '$pidFile' is not writable\n";
    close $fh;

    defined (my $pid = fork) or die "Can't fork: $!";

    if ($pid){

### RM_COMM_4_TEST ###  # remove ### RM_COMM_4_TEST ### comments for testing purpose.
### RM_COMM_4_TEST ###  return;

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
        open STDOUT, '>/dev/null' or die "ERROR: Redirecting STDOUT to /dev/null: $!";
        open STDIN, '</dev/null' or die "ERROR: Redirecting STDIN from /dev/null: $!";
        open STDERR, '>/dev/null' or die "ERROR: Redirecting STDERR to /dev/null: $!";

        # send warnings and die messages to log
        $SIG{__WARN__} = sub { $self->zLog->warn(shift) };
        $SIG{__DIE__}  = sub { return if $^S; $self->zLog->error(shift); exit 1 };

    }
};

### public methods ###
sub start {
    my $self = shift;

    $self->zLog->info("znapzend (PID=$$) starting up ...");

    $self->$daemonize if $self->daemonize;

    # set signal handlers
    $SIG{INT}  = sub { $self->zLog->debug('SIGINT received.'); $self->$killThemAll; };
    $SIG{TERM} = sub { $self->zLog->debug('SIGTERM received.'); $self->$killThemAll; };
    $SIG{HUP}  = sub {
        $self->zLog->debug('SIGHUP received.');

        #remove active timers from ioloop
        for my $backupSet (@{$self->backupSets}){
            Mojo::IOLoop->remove($backupSet->{timer_id}) if $backupSet->{timer_id};
        }
        $self->$refreshBackupPlans($self->recursive, $self->inherited, $self->dataset);
        $self->$createWorkers;
    };

    $self->$refreshBackupPlans($self->recursive, $self->inherited, $self->dataset);

    $self->$createWorkers;

    $self->zLog->info("znapzend (PID=$$) initialized -- resuming normal operations.");

    # if Mojo is running with EV, signals will not be received if the IO loop
    # is sleeping so lets activate it periodically
### RM_COMM_4_TEST ###  # remove ### RM_COMM_4_TEST ### comments for testing purpose.
### RM_COMM_4_TEST ###  if (0) {
    Mojo::IOLoop->recurring(1 => sub { }) if not $self->runonce;
### RM_COMM_4_TEST ###  }

    #start eventloop
    Mojo::IOLoop->start;

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
