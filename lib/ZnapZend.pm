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
    ZnapZend::ZFS->new(debug => $self->debug, noaction => $self->noaction, nodestroy => $self->nodestroy);
};

has zTime => sub { ZnapZend::Time->new() };

my $killThemAll  = sub {
    my $self = shift;

    for my $backupSet (@{$self->backupSets}){
        kill (SIGTERM, $backupSet->{childPid}) if $backupSet->{childPid};
    }
    exit(0);
};

my $refreshLastSnapshot = sub {
    my $self = shift;
    my $backupSet = shift;

    #get common snapshots for all destinations
    for my $dst (grep { /^dst_[^_]+$/ } (keys %{$backupSet})){
        my ($lastSnap, $lastCommonSnap) = $self->zZfs->lastAndCommonSnapshots($backupSet->{src}, $backupSet->{$dst});
        $backupSet->{lastSnap} = $lastSnap // '';
        $backupSet->{"lastCommon$dst"} = $lastCommonSnap // '';
    }
};
                          
my $refreshBackupPlans = sub {
    my $self = shift;
    $self->backupSets($self->zConfig->getBackupSetEnabled());

    die "ERROR: no backup set defined or enabled, yet. run 'znapzendzetup.pl' to setup znapzend\n" if not @{$self->backupSets};

    for my $backupSet (@{$self->backupSets}){
        $backupSet->{srcPlanHash} = $self->zTime->backupPlanToHash($backupSet->{src_plan});
        #create backup hashes for all destinations
        for (keys %{$backupSet}){
            my ($key) = /^dst_([^_]+)_[^_]+$/ or next;
            $backupSet->{"dst$key" . 'PlanHash'} = $self->zTime->backupPlanToHash($backupSet->{"dst_$key" . '_plan'});
        }
        $backupSet->{interval} = $self->zTime->getInterval($backupSet->{srcPlanHash});
#       $self->$refreshLastSnapshot($backupSet);
    }
};

my $cleanupChildren = sub {
    my $self = shift;
    my $aliveChildren = 0;

    for my $backupSet (@{$self->backupSets}){
        if ($backupSet->{childPid}){
            if(not waitpid($backupSet->{childPid}, WNOHANG)){
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

    if (not $backupSet->{childPid}){
        my $pid = fork();
        die "ERROR: could not fork child process\n" if not defined $pid;
        if(!$pid){

            my @snapshots;
            my $toDestroy;
            #loop through all destinations
            for my $dst (grep { /^dst_[^_]+$/ } (keys %{$backupSet})){
                my ($key) = $dst =~ /dst_([^_]+)$/;
                syslog('info', 'sending snapshots from ' . $backupSet->{src} . ' to ' . $backupSet->{$dst});
                #get all sub datasets of source filesystem; need to send them all individually if recursive
                my $srcSubDataSets = $backupSet->{recursive} ? $self->zZfs->listSubDataSets($backupSet->{src}) : [ $self->backupSet->{src} ];
                for my $srcDataSet (@{$srcSubDataSets}){
                    my $dstDataSet = $srcDataSet;
                    $dstDataSet =~ s/^\Q$backupSet->{src}\E/$backupSet->{$dst}/;

                    $self->zZfs->sendRecvSnapshots($srcDataSet, $dstDataSet, $backupSet->{mbuffer});
            
                    # cleanup according to backup schedule
                    @snapshots = @{$self->zZfs->listSnapshots($dstDataSet)};
                    $toDestroy = $self->zTime->getSnapshotsToDestroy(\@snapshots, $backupSet->{"dst$key" . 'PlanHash'}, $timeStamp);
                    syslog('info', 'cleaning up snapshots on ' . $dstDataSet);
                    $self->zZfs->destroySnapshots($toDestroy);
                }
            }
            #clean up source
            @snapshots = @{$self->zZfs->listSnapshots($backupSet->{src})};
            $toDestroy = $self->zTime->getSnapshotsToDestroy(\@snapshots, $backupSet->{srcPlanHash}, $timeStamp);
            syslog('info', 'cleaning up snapshots on ' . $backupSet->{src});
            $self->zZfs->destroySnapshots($toDestroy);

            #exit the forked worker
            exit(0);
        }
        else {
            $backupSet->{childPid} = $pid;
        }
    }
};

### start znapzend main loop ###
sub start {
    my $self = shift;
    
    syslog('info', 'starting znapzend...');
    # set signal handlers
    local $SIG{INT} = sub { $self->$killThemAll; };
    local $SIG{TERM} = sub { $self->$killThemAll; };

    syslog('info', 'refreshing backup plans...');
    $self->$refreshBackupPlans();

    ### main loop ###
    while(1){
        # clean up child processes
        my $cleanUp = $self->$cleanupChildren();
        # get time to wait for next snapshot creation and list of backup sets which requires action
        my ($timeStamp, $actionList) =  $self->zTime->getActionList($self->backupSets);    

        my $timeToWait = $timeStamp - time();
        sleep($cleanUp ? ($timeToWait > $self->forkPollInterval ? $self->forkPollInterval : $timeToWait) : $timeToWait);

        # check if we need to snapshot, since we start polling if child is active and might be early
        if (time() >= $timeStamp){
            for my $backupSet (@{$actionList}){
                syslog('info', 'creating snapshot on ' . $backupSet->{src});
                my $snapshotName = $backupSet->{src} . '@' . $self->zTime->createSnapshotTime($timeStamp);
                $self->zZfs->createSnapshot($snapshotName, $backupSet->{recursive});
        
                $self->$checkSendRecvCleanup($backupSet, $timeStamp);
            }
        }
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

2014-06-01 had Multi destination backup
2014-05-30 had Initial Version

=cut

