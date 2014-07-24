package ZnapZend;

use Mojo::Base -base;
use Mojo::IOLoop::ForkCall;
use Mojo::Util qw(slurp);
use Mojo::Log;
use ZnapZend::Config;
use ZnapZend::ZFS;
use ZnapZend::Time;
use POSIX qw(setsid SIGTERM);
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
has debug       => sub { 0 };
has noaction    => sub { 0 };
has nodestroy   => sub { 0 };
has runonce     => sub { q{} };
has daemonize   => sub { 0 };
has loglevel    => sub { q{debug} };
has logto       => sub { q{} };
has pidfile     => sub { q{} };

has backupSets       => sub { [] };

has zConfig => sub {
    my $self = shift;
    ZnapZend::Config->new(debug => $self->debug, noaction => $self->noaction);
};

has zZfs => sub {
    my $self = shift;
    ZnapZend::ZFS->new(debug => $self->debug,
        noaction => $self->noaction, nodestroy => $self->nodestroy);
};

has zTime => sub { ZnapZend::Time->new() };

has zLog => sub {
    my $self = shift;

    #check if we are logging to syslog
    my ($syslog) = $self->logto =~ /^syslog::(\w+)$/;

    #make level mojo conform
    my ($level) = grep { $logLevels{$_} eq $self->loglevel } keys %logLevels
        or die "ERROR: only log levels '" . join("', '", values %logLevels)
            . "' are supported\n";

    my $log = Mojo::Log->new(path => $syslog ? '/dev/null'
        : $self->logto, level => $level);

    #default logging to STDERR if runonce
    $self->runonce && !$self->logto && do {
        $log->unsubscribe('message');
        #log to STDERR
        $log->on(
            message => sub {
                my ($log, $level, @lines) = @_;
                print STDERR '[' . localtime . '] ['
                    . $level . '] ' . join(' ', @lines) . "\n";
            }
        );

        return $log;
    };
    #default logging to syslog
    ($syslog || !$self->logto) && do {
        $log->unsubscribe('message');
        #add syslog handler if either syslog is explicitly specified or no logfile is given
        openlog(basename($0), 'cons,pid', $syslog || 'local6');
        $log->on(
            message => sub {
                my ($log, $level, @lines) = @_;
                syslog($logLevels{$level}, @lines);
            }
        );

        return $log;
    };
    #logging to file
    return $log;
};

my $killThemAll  = sub {
    my $self = shift;

    Mojo::IOLoop->reset;

    for my $backupSet (@{$self->backupSets}){
        kill (SIGTERM, $backupSet->{snap_pid}) if $backupSet->{snap_pid};
        kill (SIGTERM, $backupSet->{send_pid}) if $backupSet->{send_pid};
    }
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

            #check if destination exists (i.e. is valid) otherwise remove it
            if (!$backupSet->{"dst_$key" . '_valid'}){
                $self->zLog->warn("destination '" . $backupSet->{"dst_$key"}
                    . "' does not exist. ignoring it...");
                print STDERR "\n# WARNING: destination '" . $backupSet->{"dst_$key"}
                    . "' does not exist. ignoring it...\n\n" if $self->debug;

                delete $backupSet->{"dst_$key"};
                next;
            }
            $backupSet->{"dst$key" . 'PlanHash'}
                = $self->zTime->backupPlanToHash($backupSet->{"dst_$key" . '_plan'});
        }
        $backupSet->{interval}   = $self->zTime->getInterval($backupSet->{srcPlanHash});
        $backupSet->{snapFilter} = $self->zTime->getSnapshotFilter($backupSet->{tsformat});
        $self->zLog->info("found a valid backup plan for $backupSet->{src}...");
    }
};

my $sendRecvCleanup = sub {
    my $self = shift;
    my $backupSet = shift;
    my $timeStamp = shift;

    my @snapshots;
    my $toDestroy;

    #get all sub datasets of source filesystem; need to send them all individually if recursive
    my $srcSubDataSets = $backupSet->{recursive} eq 'on'
        ? $self->zZfs->listSubDataSets($backupSet->{src}) : [ $backupSet->{src} ];

    #loop through all destinations
    for my $dst (grep { /^dst_[^_]+$/ } keys %$backupSet){
        my ($key) = $dst =~ /dst_([^_]+)$/;

        #loop through all subdatasets
        for my $srcDataSet (@$srcSubDataSets){
            my $dstDataSet = $srcDataSet;
            $dstDataSet =~ s/^\Q$backupSet->{src}\E/$backupSet->{$dst}/;

            $self->zLog->info('sending snapshots from ' . $srcDataSet . ' to ' . $dstDataSet);
            $self->zZfs->sendRecvSnapshots($srcDataSet, $dstDataSet,
                $backupSet->{mbuffer}, $backupSet->{mbuffer_size}, $backupSet->{snapFilter});
            
            # cleanup according to backup schedule
            @snapshots = @{$self->zZfs->listSnapshots($dstDataSet, $backupSet->{snapFilter})};
            $toDestroy = $self->zTime->getSnapshotsToDestroy(\@snapshots,
                         $backupSet->{"dst$key" . 'PlanHash'}, $backupSet->{tsformat}, $timeStamp);

            $self->zLog->info('cleaning up snapshots on ' . $dstDataSet);
            $self->zZfs->destroySnapshots($toDestroy);
        }
    }

    #cleanup source
    for my $srcDataSet (@$srcSubDataSets){
        # cleanup according to backup schedule
        @snapshots = @{$self->zZfs->listSnapshots($srcDataSet, $backupSet->{snapFilter})};
        $toDestroy = $self->zTime->getSnapshotsToDestroy(\@snapshots,
                     $backupSet->{srcPlanHash}, $backupSet->{tsformat}, $timeStamp);

        $self->zLog->info('cleaning up snapshots on ' . $srcDataSet);
        $self->zZfs->destroySnapshots($toDestroy);
    }
};

my $createSnapshot = sub {
    my $self = shift;
    my $backupSet = shift;
    my $timeStamp = shift;
 
    if ($backupSet->{pre_znap_cmd} && $backupSet->{pre_znap_cmd} ne 'off'){
        $self->zLog->info("running pre snapshot command on $backupSet->{src}");

        system($backupSet->{pre_znap_cmd})
            && $self->zLog->warn("running pre snapshot command on $backupSet->{src} failed");
    }

    $self->zLog->info('creating ' . ($backupSet->{recursive} eq 'on' ? 'recursive ' : '')
        . 'snapshot on ' . $backupSet->{src});

    my $snapshotName = $backupSet->{src} . '@'
        . $self->zTime->createSnapshotTime($timeStamp, $backupSet->{tsformat});

    $self->zZfs->createSnapshot($snapshotName, $backupSet->{recursive} eq 'on')
        or $self->zLog->info("snapshot '$snapshotName' does already exist. skipping one round...");

    if ($backupSet->{post_znap_cmd} && $backupSet->{post_znap_cmd} ne 'off'){
        $self->zLog->info("running post snapshot command on $backupSet->{src}");

        system($backupSet->{post_znap_cmd})
            && $self->zLog->warn("running post snapshot command on $backupSet->{src} failed");
    }
};

my $sendWorker = sub {
    my $self = shift;
    my $backupSet = shift;
    my $timeStamp = shift;

### RM_COMM_4_TEST ###  # remove ### RM_COMM_4_TEST ### comments for testing purpose.
### RM_COMM_4_TEST ###  $self->$sendRecvCleanup($backupSet, $timeStamp);
### RM_COMM_4_TEST ###  return 0;

    #send/receive fork
    my $fc = Mojo::IOLoop::ForkCall->new;
    my $pid = $fc->run(
        #send/receive worker
        $sendRecvCleanup,
        #send/receive worker arguments
        [$self, $backupSet, $timeStamp],
        #send/receive worker callback
        sub {
            my ($fc, $err) = @_;

            $self->zLog->warn($err) if $err;
            #send/receive process finished, clear pid from backup set
            $backupSet->{send_pid} = 0;
        }
    );

    return $pid;
};

my $snapWorker = sub {
    my $self = shift;
    my $backupSet = shift;
    my $timeStamp = shift;

### RM_COMM_4_TEST ###  # remove ### RM_COMM_4_TEST ### comments for testing purpose.
### RM_COMM_4_TEST ###  $self->$createSnapshot($backupSet, $timeStamp);
### RM_COMM_4_TEST ###  $self->$sendWorker($backupSet, $timeStamp);
### RM_COMM_4_TEST ###  return 0;

    #snapshot fork
    my $fc = Mojo::IOLoop::ForkCall->new;
    my $pid = $fc->run(
        #snapshot worker
        $createSnapshot,
        #snapshot worker arguments
        [$self, $backupSet, $timeStamp],
        #snapshot worker callback
        sub {
            my ($fc, $err) = @_;
            
            $self->zLog->warn($err) if $err;
            #snapshot process finished, clear pid from backup set
            $backupSet->{snap_pid} = 0;

            if ($backupSet->{send_pid}){
                $self->zLog->info('last send/receive process on ' . $backupSet->{src}
                    . ' still running! skipping this round...');
            }
            else{
                $backupSet->{send_pid} = $self->$sendWorker($backupSet, $timeStamp);
            }
        }
    );

    return $pid;
};

my $createWorkers = sub {
    my $self = shift;

    #create a timer for each backup set
    for my $backupSet (@{$self->backupSets}){
        #calculate next snapshot timestamp
        my $timeStamp = $self->zTime->getNextSnapshotTimestamp($backupSet);
        #define timer callback
        my $cb;
        $cb = sub {
            #check if we run too early (can be caused by DST time 'jump')
            my $timeDelta = $timeStamp - $self->zTime->getLocalTimestamp();
            if ($timeDelta > 0){
                Mojo::IOLoop->timer($timeDelta => $cb);
                return;
            }

            if ($backupSet->{snap_pid}){
                $self->zLog->warn('last snapshot process still running! it seems your pre or '
                    . 'post snapshot script runs for ages. snapshot will not be taken this time!');
            }
            else{
                $backupSet->{snap_pid} = $self->$snapWorker($backupSet, $timeStamp);
            }

### RM_COMM_4_TEST ###  # remove ### RM_COMM_4_TEST ### comments for testing purpose.
### RM_COMM_4_TEST ###  return 1;

            #get next timestamp when a snapshot has to be taken
            $timeStamp = $self->zTime->getNextSnapshotTimestamp($backupSet);

            #reset timer for next snapshot if not runonce
            Mojo::IOLoop->timer($timeStamp - $self->zTime->getLocalTimestamp() => $cb) if !$self->runonce;
        };

        #set timer for next snapshot or run immediately if runonce
        if ($self->runonce){
            #run immediately
            $timeStamp = $self->zTime->getLocalTimestamp();
            $cb->();
        }
        else{
            Mojo::IOLoop->timer($timeStamp - $self->zTime->getLocalTimestamp() => $cb);
        }
    };

};

my $daemonize = sub {
    my $self = shift;
    my $pidFile = $self->pidfile;

    if (defined $pidFile && -f $pidFile){
        chomp(my $pid = slurp $pidFile);
        if (kill 0, $pid){
            die "I Quit! Another copy of znapzend ($pid) seems to be running. See $pidFile\n";
        }
    }
    defined (my $pid = fork) or die "Can't fork: $!";

    if ($pid){

### RM_COMM_4_TEST ###  # remove ### RM_COMM_4_TEST ### comments for testing purpose.
### RM_COMM_4_TEST ###  return 1;

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

    $self->$daemonize if $self->daemonize;

    # set signal handlers
    local $SIG{INT}  = sub { $self->$killThemAll; };
    local $SIG{TERM} = sub { $self->$killThemAll; };

    $self->$refreshBackupPlans($self->runonce);

    $self->$createWorkers;

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

