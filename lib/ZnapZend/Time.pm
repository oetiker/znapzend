package ZnapZend::Time;

use Mojo::Base -base;
use Time::Local qw(timelocal);
use POSIX qw(strftime);

### attributes ###
has configUnits => sub {
    {
        s       => 'seconds',
        sec     => 'seconds',
        second  => 'seconds',
        M       => 'minutes',
        min     => 'minutes',
        mins    => 'minutes',
        minute  => 'minutes',
        h       => 'hours',
        hour    => 'hours',
        d       => 'days',
        day     => 'days',
        w       => 'weeks',
        week    => 'weeks',
        m       => 'months',
        mon     => 'months',
        mons    => 'months',
        month   => 'months',
        y       => 'years',
        year    => 'years',
    }
};

has unitFactors => sub {
    {
        years   => 3600 * 24 * 366,
        months  => 3600 * 24 * 31,
        weeks   => 3600 * 24 * 7,
        days    => 3600 * 24,
        hours   => 3600,
        minutes => 60,
        seconds => 1,
    }
};

has monthTable => sub {
    {
        Jan     => 0,
        Feb     => 1,
        Mar     => 2,
        Apr     => 3,
        May     => 4,
        Jun     => 5,
        Jul     => 6,
        Aug     => 7,
        Sep     => 8,
        Oct     => 9,
        Nov     => 10,
        Dec     => 11,
    }
};

has snapshotTimeFormat => sub { '%Y-%m-%d-%H%M%S' };
has snapshotFilter => sub { qr/(\d{4})-(\d{2})-(\d{2})-(\d{2})(\d{2})(\d{2})/ };
has scrubFilter => sub { qr/scrub repaired/ };
has scrubTimeFormat => sub { qr/([A-Z][a-z]{2})\s+(\d{1,2})\s+(\d{2}):(\d{2}):(\d{2})\s+(\d{4})$/ };

my $intervalToTimestamp = sub {
    my $time = shift;
    my $interval = shift;

    return $interval * (int($time / $interval) + 1);
    
};

my $timeToTimestamp = sub {
    my $self = shift;
    my ($time, $unit) = @_;

    return $time * $self->unitFactors->{$unit};
};

my $getSnapshotTimestamp = sub {
    my $self = shift;
    my $snapshotFilter = $self->snapshotFilter;
    if (my ($year, $month, $day, $hour, $min, $sec) = $_[0] =~ /^.*\@$snapshotFilter$/){
        return timelocal($sec, $min, $hour, $day, $month - 1, $year);
    }
    return 0;
};

### public methods ###
sub checkTimeUnit {
    my $self = shift;
    my $arg = shift;
    my ($time, $unit) = $arg =~ /^(\d+)\s*(\w+)$/;

    if ($time && $unit){
        return $time . $self->configUnits()->{$unit} if (exists $self->configUnits->{$unit});
        return "$time$unit" if grep { $_ eq $unit } values %{$self->configUnits};
    }
    return undef;
};

sub backupPlanToHash {
    my $self = shift;
    my $backupPlan = shift;
    my %backupPlan;

    my @planItems = split ',', $backupPlan;

    for my $planItem (@planItems){
        my @planValues = split '=>', $planItem, 2;
        my ($value, $unit) = $planValues[0] =~ /(\d+)([a-z]+)/;
        die "ERROR: backup plan $backupPlan is not valid\n" if not defined $value and exists $self->unitFactors->{$unit};
        my $key = $self->$timeToTimestamp($value, $unit);
        ($value, $unit) = $planValues[1] =~ /(\d+)([a-z]+)/;
        die "ERROR: backup plan $backupPlan ist not valid\n" if not defined $value and exists $self->unitFactors->{$unit};
        $backupPlan{$key} = $self->$timeToTimestamp($value, $unit);
    }

    return \%backupPlan;
}

sub getInterval {
    my $self = shift;
    my $backupHash = shift;

    return (sort { $a<=>$b } (values %{$backupHash}))[0];
}

sub createSnapshotTime {
    my $self = shift;
    my $timeStamp = shift;
    return strftime($self->snapshotTimeFormat, localtime($timeStamp));
}

sub getActionList {
    my $self = shift;
    my $backupSets = shift;
    my $timeStamp = undef;
    my @backupSets;
    my $time = time();

    for my $backupSet (@{$backupSets}){
        my $tmpTime = $intervalToTimestamp->($time, $backupSet->{interval});
        
        if (not defined $timeStamp or $tmpTime < $timeStamp){
            $timeStamp = $tmpTime;
            @backupSets = ();
        }
        push @backupSets, $backupSet if $timeStamp == $tmpTime;
    }
    return ($timeStamp, \@backupSets);
}

sub getSnapshotsToDestroy {
    my $self = shift;
    my $snapshots = shift;
    my $timePlan = shift;
    my $time = $_[0] || time();
    my %timeslots;
    my @toDestroy;

    #initialise with maximum time to keep backups since we run from old to new backups
    my $maxAge = (sort { $b<=>$a } keys %{$timePlan})[0];

    for my $snapshot (@{$snapshots}){
        #get snapshot age
        my $snapshotTimestamp = $self->$getSnapshotTimestamp($snapshot);
        my $snapshotAge = $time - $snapshotTimestamp;
        #get valid snapshot schedule for this dataset
        for my $key (sort { $a<=>$b } keys %{$timePlan}){
            if ($key >= $snapshotAge){
                $maxAge = $key;
                last;
            }
        }
        #maxAge should never be 0 or less, still do a check for safety
        die "ERROR: snapshot maximum age is 0! this would delete all your snapshots.\n" if not $maxAge > 0;
        #check if snapshot is older than the maximum age; removes all snapshots that are older than the maximum time to keep
        if ($snapshotAge > $maxAge){
            push @toDestroy, $snapshot;
            next;
        }
        #calculate timeslot
        my $timeslot = int($snapshotTimestamp / $timePlan->{$maxAge});
        #check if timeslot is already occupied, if so, push this snapshot to the destroy list
        if (exists $timeslots{$maxAge} and exists $timeslots{$maxAge}->{$timeslot}){
            push @toDestroy, $snapshot;
        }
        else{
            #define timeslot
            $timeslots{$maxAge}->{$timeslot} = '';
        }
    }
    return \@toDestroy;
}

sub getLastScrubTimestamp {
    my $self = shift;
    my $zpoolStatus = shift;
    my $scrubFilter = $self->scrubFilter;
    my $scrubTimeFormat = $self->scrubTimeFormat;

    for (@{$zpoolStatus}){
        next if not /$scrubFilter/;
        say $_;
        if (my ($month, $day, $hour, $min, $sec, $year) = /$scrubTimeFormat/){
            return timelocal($sec, $min, $hour, $day, $self->monthTable->{$month}, $year);
        }
    }
    return 0;
}

1;

__END__

=head1 NAME

ZnapZend::Time - znapzend time class

=head1 SYNOPSIS

use ZnapZend::Time;
...
my $zTime = ZnapZend::Time->new();
...

=head1 DESCRIPTION

znapzend time management class

=head1 ATTRIBUTES

=head2 debug

print debug information to STDERR

=head2 noaction

do a dry run. no changes to the filesystem will be performed

=head1 METHODS

=head2 checkTimeUnit

checks if time and time unit are valid

=head2 backupPlanToHash

converts a backup plan to a timestamp hash

=head2 getInterval

returns the smallest time interval within a backup plan -> this will be the snapshot creation interval

=head2 createSnapshotTime

returns a formatted string (according to snapshotTimeFormat attribute) from a timestamp

=head2 getActionList

returns a timestamp when the next action (i.e. snapshot creation) has to be done and returns a list of backup plans which need action

=head2 snapshotsToDestroy

returns a list of snapshots which have to be destroyed according to the backup plan

=head2 getLastScrubTimestamp

extracts the time scrub ran (and finished) last on a pool

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

