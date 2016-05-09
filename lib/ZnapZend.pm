package ZnapZend;

use Mojo::Base -base;
use Mojo::IOLoop::ForkCall;
use Mojo::Util qw(slurp);
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
has debug           => sub { 0 };
has noaction        => sub { 0 };
has nodestroy       => sub { 0 };
has oracleMode      => sub { 0 };
has recvu           => sub { 0 };
has pfexec          => sub { 0 };
has sudo            => sub { 0 };
has connectTimeout  => sub { 30 };
has runonce         => sub { q{} };
has daemonize       => sub { 0 };
has loglevel        => sub { q{debug} };
has logto           => sub { q{} };
has pidfile         => sub { q{} };
has defaultPidFile  => sub { q{/var/run/znapzend.pid} };
has terminate       => sub { 0 };
has autoCreation    => sub { 0 };

has backupSets       => sub { [] };

has zConfig => sub {
    my $self = shift;
    ZnapZend::Config->new(debug => $self->debug, noaction => $self->noaction,
                          pfexec => $self->pfexec, sudo => $self->sudo);
};

has zZfs => sub {
    my $self = shift;
    ZnapZend::ZFS->new(debug => $self->debug, noaction => $self->noaction,
        nodestroy => $self->nodestroy, oracleMode => $self->oracleMode,
        recvu => $self->recvu, connectTimeout => $self->connectTimeout,
        pfexec => $self->pfexec, sudo => $self->sudo,
        zLog => $self->zLog,autoCreation => $self->autoCreation);
        
};

has zTime => sub { ZnapZend::Time->new() };

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
                syslog($logLevels{$level}, @lines);
            }
        );
    };

    return $log;
};

my $killThemAll  = sub {
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
    my $dataSet = shift;

    $self->zLog->info('refreshing backup plans...');
    $self->backupSets($self->zConfig->getBackupSetEnabled($dataSet));

    @{$self->backupSets}
        or die "ERROR: no backup set defined or enabled, yet. run 'znapzendzetup' to setup znapzend\n";

    for my $backupSet (@{$self->backupSets}){
        $backupSet->{srcPlanHash} = $self->zTime->backupPlanToHash($backupSet->{src_plan});
        #create backup hashes for all destinations
        for (keys %$backupSet){
            my ($key) = /^dst_([^_]+)_plan$/ or next;

            #check if destination exists (i.e. is valid) otherwise recheck as dst might be online, now 
            if (!$backupSet->{"dst_$key" . '_valid'}){
                my $dstPath = $backupSet->{"dst_$key"};
                if ($self->autoCreation) {
                    # in auto create mode we are happy if
                    # the pool exists
                    $dstPath =~ s{/.+}{};
                }
                $backupSet->{"dst_$key" . '_valid'}
                    = $self->zZfs->dataSetExists($dstPath) or do {

                    $self->zLog->warn("destination '" . $dstPath
                        . "' does not exist or is offline. will be rechecked every run...");
                };
            }
            $backupSet->{"dst$key" . 'PlanHash'}
                = $self->zTime->backupPlanToHash($backupSet->{"dst_$key" . '_plan'});
        }
        $backupSet->{interval}   = $self->zTime->getInterval($backupSet->{srcPlanHash});
        $backupSet->{snapFilter} = $self->zTime->getSnapshotFilter($backupSet->{tsformat});
        $backupSet->{UTC}        = $self->zTime->useUTC($backupSet->{tsformat});
        $self->zLog->info("found a valid backup plan for $backupSet->{src}...");
    }
};

my $sendRecvCleanup = sub {
    my $self = shift;
    my $backupSet = shift;
    my $timeStamp = shift;

    #no HUP handler in child
    $SIG{HUP} = 'IGNORE';

    my @snapshots;
    my $toDestroy;
    my $sendFailed = 0;
    my $startTime = time;
    $self->zLog->info('starting work on backupSet ' . $backupSet->{src});
    
    #get all sub datasets of source filesystem; need to send them all individually if recursive
    my $srcSubDataSets = $backupSet->{recursive} eq 'on'
        ? $self->zZfs->listSubDataSets($backupSet->{src}) : [ $backupSet->{src} ];

    #loop through all destinations
    for my $dst (sort grep { /^dst_[^_]+$/ } keys %$backupSet){
        my ($key) = $dst =~ /dst_([^_]+)$/;

        #recheck non valid dst as t might be online, now 
        if (!$backupSet->{$dst . '_valid'}){
            my $dstPath = $backupSet->{"$dst"};
            if ($self->autoCreation) {
                # in auto create mode we are happy if
                # the pool exists
                $dstPath =~ s{/.+}{};
            }
            
            $backupSet->{$dst. '_valid'}
                = $self->zZfs->dataSetExists($dstPath) or do {

                $self->zLog->warn("destination '" . $dstPath
                    . "' does not exist or is offline. ignoring it for this round...");
                next;
            };
        }

        #loop through all subdatasets
        for my $srcDataSet (@$srcSubDataSets){
            my $dstDataSet = $srcDataSet;
            $dstDataSet =~ s/^\Q$backupSet->{src}\E/$backupSet->{$dst}/;

            $self->zLog->debug('sending snapshots from ' . $srcDataSet . ' to ' . $dstDataSet);
            {
                local $@;
                eval {
                    local $SIG{__DIE__};
                    $self->zZfs->sendRecvSnapshots($srcDataSet, $dstDataSet,
                        $backupSet->{mbuffer}, $backupSet->{mbuffer_size}, $backupSet->{snapFilter});
                };
                if ($@){
                    $sendFailed = 1;
                    if (blessed $@ && $@->isa('Mojo::Exception')){
                        $self->zLog->warn($@->message);
                    }
                    else{
                        $self->zLog->warn($@);
                    }
                }
            }
        } 
        for my $srcDataSet (@$srcSubDataSets){
            my $dstDataSet = $srcDataSet;
            $dstDataSet =~ s/^\Q$backupSet->{src}\E/$backupSet->{$dst}/;

            # cleanup according to backup schedule
            @snapshots = @{$self->zZfs->listSnapshots($dstDataSet, $backupSet->{snapFilter})};
            $toDestroy = $self->zTime->getSnapshotsToDestroy(\@snapshots,
                         $backupSet->{"dst$key" . 'PlanHash'}, $backupSet->{tsformat}, $timeStamp);

            $self->zLog->debug('cleaning up snapshots on ' . $dstDataSet);
            {
                local $@;
                eval {
                    local $SIG{__DIE__};
                    $self->zZfs->destroySnapshots($toDestroy);
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

    #cleanup source
    if ($sendFailed){
        $self->zLog->warn('ERROR: suspending cleanup source dataset because at least one send task failed');
    }
    else{
        for my $srcDataSet (@$srcSubDataSets){
            # cleanup according to backup schedule
            @snapshots = @{$self->zZfs->listSnapshots($srcDataSet, $backupSet->{snapFilter})};
            $toDestroy = $self->zTime->getSnapshotsToDestroy(\@snapshots,
                         $backupSet->{srcPlanHash}, $backupSet->{tsformat}, $timeStamp);

            $self->zLog->debug('cleaning up snapshots on ' . $srcDataSet);
            {
                local $@;
                eval {
                    local $SIG{__DIE__};
                    $self->zZfs->destroySnapshots($toDestroy);
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

    my $snapshotName = $backupSet->{src} . '@'
        . $self->zTime->createSnapshotTime($timeStamp, $backupSet->{tsformat});

    #set env variables for pre and post scripts use
    local $ENV{ZNAP_NAME} = $snapshotName;
    local $ENV{ZNAP_TIME} = $timeStamp;
 
    if ($backupSet->{pre_znap_cmd} && $backupSet->{pre_znap_cmd} ne 'off'){
        $self->zLog->info("running pre snapshot command on $backupSet->{src}");

        system($backupSet->{pre_znap_cmd})
            && $self->zLog->warn("running pre snapshot command on $backupSet->{src} failed");
    }

    $self->zLog->info('creating ' . ($backupSet->{recursive} eq 'on' ? 'recursive ' : '')
        . 'snapshot on ' . $backupSet->{src});

    $self->zZfs->createSnapshot($snapshotName, $backupSet->{recursive} eq 'on')
        or $self->zLog->info("snapshot '$snapshotName' does already exist. skipping one round...");

    if ($backupSet->{post_znap_cmd} && $backupSet->{post_znap_cmd} ne 'off'){
        $self->zLog->info("running post snapshot command on $backupSet->{src}");

        system($backupSet->{post_znap_cmd})
            && $self->zLog->warn("running post snapshot command on $backupSet->{src} failed");
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
        chomp(my $pid = slurp $pidFile);
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
        $self->$refreshBackupPlans($self->runonce);
        $self->$createWorkers;
    };
    
    $self->$refreshBackupPlans($self->runonce);

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

2014-07-22 had Pre and post snapshot commands
2014-06-29 had Flexible snapshot time format
2014-06-10 had localtime implementation
2014-06-01 had Multi destination backup
2014-05-30 had Initial Version

=cut

