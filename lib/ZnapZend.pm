package ZnapZend;

use Mojo::Base -base;
use ZnapZend::Config;
use ZnapZend::ZFS;
use ZnapZend::Time;
use POSIX qw(WNOHANG SIGTERM);
use Sys::Syslog;

### attributes ###
has debug       => sub { 0 };
has noaction    => sub { 0 };
has nodestroy   => sub { 1 };

has backupSets  => sub { [] };
has forkPollInterval => sub { 5 };

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

my $killThemAll  = sub {
    my $self = shift;

    for my $backupSet (@{$self->backupSets}){
        kill (SIGTERM, $backupSet->{childPid}) if $backupSet->{childPid};
    }
    exit 0;
};

my $refreshBackupPlans = sub {
    my $self = shift;
    $self->backupSets($self->zConfig->getBackupSetEnabled());

    @{$self->backupSets}
        or die "ERROR: no backup set defined or enabled, yet. run 'znapzendzetup' to setup znapzend\n";

    for my $backupSet (@{$self->backupSets}){
        $backupSet->{srcPlanHash} = $self->zTime->backupPlanToHash($backupSet->{src_plan});
        #create backup hashes for all destinations
        for (keys %{$backupSet}){
            my ($key) = /^dst_([^_]+)_[^_]+$/ or next;
            $backupSet->{"dst$key" . 'PlanHash'}
                = $self->zTime->backupPlanToHash($backupSet->{"dst_$key" . '_plan'});
        }
        $backupSet->{interval} = $self->zTime->getInterval($backupSet->{srcPlanHash});
        $backupSet->{snapFilter} = $self->zTime->getSnapshotFilter($backupSet->{tsformat});
        syslog('info', "found a valid backup plan for $backupSet->{src}...");
    }
};

my $cleanupChildren = sub {
    my $self = shift;
    my $aliveChildren = 0;

    for my $backupSet (@{$self->backupSets}){
        if ($backupSet->{childPid}){
            if (!waitpid($backupSet->{childPid}, WNOHANG)){
                $aliveChildren++;
            }
            else{
                $backupSet->{childPid} = 0;
            }
        }
    }
    return $aliveChildren;
};

my $checkSendRecvCleanup = sub {
    my $self = shift;
    my $backupSet = shift;
    my $timeStamp = shift;

    if (!$backupSet->{childPid}){
        my $pid = fork();
        defined $pid or die "ERROR: could not fork child process\n";

        if(!$pid){
            my @snapshots;
            my $toDestroy;

            #get all sub datasets of source filesystem; need to send them all individually if recursive
            my $srcSubDataSets = $backupSet->{recursive} eq 'on'
                ? $self->zZfs->listSubDataSets($backupSet->{src}) : [ $backupSet->{src} ];

            #loop through all destinations
            for my $dst (grep { /^dst_[^_]+$/ } (keys %{$backupSet})){
                my ($key) = $dst =~ /dst_([^_]+)$/;

                #loop through all subdatasets
                for my $srcDataSet (@{$srcSubDataSets}){
                    my $dstDataSet = $srcDataSet;
                    $dstDataSet =~ s/^\Q$backupSet->{src}\E/$backupSet->{$dst}/;

                    syslog('info', 'sending snapshots from ' . $srcDataSet . ' to ' . $dstDataSet);
                    $self->zZfs->sendRecvSnapshots($srcDataSet,
                        $dstDataSet, $backupSet->{mbuffer}, $backupSet->{snapFilter});
            
                    # cleanup according to backup schedule
                    @snapshots = @{$self->zZfs->listSnapshots($dstDataSet, $backupSet->{snapFilter})};
                    $toDestroy = $self->zTime->getSnapshotsToDestroy(\@snapshots,
                                 $backupSet->{"dst$key" . 'PlanHash'}, $backupSet->{tsformat}, $timeStamp);

                    syslog('info', 'cleaning up snapshots on ' . $dstDataSet);
                    $self->zZfs->destroySnapshots($toDestroy);
                }
            }

            #cleanup source
            for my $srcDataSet (@{$srcSubDataSets}){
                # cleanup according to backup schedule
                @snapshots = @{$self->zZfs->listSnapshots($srcDataSet, $backupSet->{snapFilter})};
                $toDestroy = $self->zTime->getSnapshotsToDestroy(\@snapshots,
                             $backupSet->{srcPlanHash}, $backupSet->{tsformat}, $timeStamp);

                syslog('info', 'cleaning up snapshots on ' . $srcDataSet);
                $self->zZfs->destroySnapshots($toDestroy);
            }

            #exit the forked worker
            exit(0);
        }
        else {
            #parent process, save child pid
            $backupSet->{childPid} = $pid;
        }
    }
};

### start znapzend main loop ###
sub start {
    my $self = shift;
    
    syslog('info', 'starting znapzend...');
    # set signal handlers
    local $SIG{INT}  = sub { $self->$killThemAll; };
    local $SIG{TERM} = sub { $self->$killThemAll; };

    syslog('info', 'refreshing backup plans...');
    $self->$refreshBackupPlans();

    ### main loop ###
    while (1){
        # clean up child processes
        my $cleanUp = $self->$cleanupChildren();
        # get time to wait for next snapshot creation and list of backup sets which requires action
        my ($timeStamp, $actionList) =  $self->zTime->getActionList($self->backupSets);    
        my $timeToWait = $timeStamp - $self->zTime->getLocalTimestamp();

        if ($cleanUp){
            sleep($timeToWait > $self->forkPollInterval ? $self->forkPollInterval : $timeToWait);
        }
        else{
            syslog('info', 'nothing to do for me. am so bored... off for a coffee break.'
                . " will be back in $timeToWait seconds to serve you, my master");

            sleep $timeToWait;
        }

        # check if we need to snapshot, since we start polling if child is active and might be early
        if ($self->zTime->getLocalTimestamp() >= $timeStamp){
            for my $backupSet (@{$actionList}){
                syslog('info', 'creating ' . ($backupSet->{recursive} eq 'on' ? 'recursive ' : '')
                    . 'snapshot on ' . $backupSet->{src});

                my $snapshotName = $backupSet->{src} . '@'
                    . $self->zTime->createSnapshotTime($timeStamp, $backupSet->{tsformat});

                $self->zZfs->createSnapshot($snapshotName, $backupSet->{recursive} eq 'on')
                    or syslog('info', "snapshot '$snapshotName' does already exist. skipping one round...");
        
                $self->$checkSendRecvCleanup($backupSet, $timeStamp);
            }
        }
### RM_COMM_4_TEST ###  # remove ### RM_COMM_4_TEST ### comments for testing purpose.
### RM_COMM_4_TEST ###  while ($self->$cleanupChildren()){
### RM_COMM_4_TEST ###      sleep 1;
### RM_COMM_4_TEST ###  }
### RM_COMM_4_TEST ###  return 1;
    }    
}

1;

__END__

=head1 NAME

ZnapZend::Worker - znapzend worker class

=head1 SYNOPSIS

use ZnapZend::Worker;
...
my $zWorker = ZnapZend::Worker->new(debug=>0, noaction=>0, nodestroy=>0);
...

=head1 DESCRIPTION

main znapzend controller. does the scheduling and executes the necessary commands

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
S<Dominik Hassler>

=head1 HISTORY

2014-06-29 had Flexible snapshot time format
2014-06-10 had localtime implementation
2014-06-01 had Multi destination backup
2014-05-30 had Initial Version

=cut

