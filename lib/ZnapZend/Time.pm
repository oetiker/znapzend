package ZnapZend::Time;

use Mojo::Base -base;
use Time::Piece;
use Time::Seconds;

### attributes ###
has configUnits => sub {
    {
        s       => 'seconds',
        sec     => 'seconds',
        second  => 'seconds',
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
        years   => 3600 * 24 * 365.25,
        months  => 3600 * 24 * 30,
        weeks   => 3600 * 24 * 7,
        days    => 3600 * 24,
        hours   => 3600,
        minutes => 60,
        seconds => 1,
    }
};

has scrubFilter     => sub { qr/scrub repaired/ };
has scrubTimeFilter => sub { qr/[A-Z][a-z]{2}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2}\s+\d{4}/ };
has scrubTimeFormat => sub { q{%b %d %H:%M:%S %Y} };
has timeWarp        => sub { undef };

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
    my $snapshot = shift;
    my $timeFormat = shift;

    my $snapFilter = $self->getSnapshotFilter($timeFormat);

    if (my ($snapshotTimestamp) = $snapshot =~ /^.+\@($snapFilter)$/){
        my $snapshotTime = Time::Piece->strptime($snapshotTimestamp, $timeFormat)
            or die "ERROR: cannot extract time of '$snapshot'\n";

        return $snapshotTime->epoch;
    }

    return 0;
};

### public methods ###
sub checkTimeUnit {
    my $self = shift;
    my $arg = shift;
    my ($time, $unit) = $arg =~ /^(\d+)\s*([a-z]+)$/;

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

    my @planItems = split /,/, $backupPlan;

    for my $planItem (@planItems){
        my @planValues = split '=>', $planItem, 2;
        my ($value, $unit) = $planValues[0] =~ /^(\d+)([a-z]+)$/;
        $value && exists $self->unitFactors->{$unit}
            or die "ERROR: backup plan $backupPlan is not valid\n";

        my $key = $self->$timeToTimestamp($value, $unit);
        exists $backupPlan{$key}
            and die "ERROR: retention time '$value$unit' already specified\n";

        ($value, $unit) = $planValues[1] =~ /^(\d+)([a-z]+)$/;
        $value && exists $self->unitFactors->{$unit}
            or die "ERROR: backup plan $backupPlan ist not valid\n";

        $backupPlan{$key} = $self->$timeToTimestamp($value, $unit);
    }

    return \%backupPlan;
}

sub useUTC {
    my $self = shift;
    my $timeFormat = shift;
    
    return $timeFormat =~ /Z$/;
}

sub getInterval {
    my $self = shift;
    my $backupHash = shift;

    return (sort { $a<=>$b } (values %$backupHash))[0];
}

sub createSnapshotTime {
    my $self = shift;
    my $timeStamp = shift;
    my $timeFormat = shift;

    my $time = gmtime($timeStamp);
    return $time->strftime($timeFormat);
}

sub getNextSnapshotTimestamp {
    my $self = shift;
    my $interval = shift;
    #useUTC is second argument
    my $time = $self->getTimestamp(shift);

    return $intervalToTimestamp->($time, $interval);
}

sub getSnapshotsToDestroy {
    my $self = shift;
    my $snapshots = shift;
    my $timePlan = shift;
    my $timeFormat = shift;
    my $time = $_[0] || $self->getTimestamp($self->useUTC($timeFormat));
    my %timeslots;
    my @toDestroy;

    #initialise with maximum time to keep backups since we run from old to new backups
    my $maxAge = (sort { $a<=>$b } keys %$timePlan)[-1];

    for my $snapshot (@$snapshots){
        #get snapshot age
        my $snapshotTimestamp = $self->$getSnapshotTimestamp($snapshot, $timeFormat);
        my $snapshotAge = $time - $snapshotTimestamp;
        #get valid snapshot schedule for this dataset
        for my $key (sort { $a<=>$b } keys %$timePlan){
            if ($key >= $snapshotAge){
                $maxAge = $key;
                last;
            }
        }
        #maxAge should never be 0 or less, still do a check for safety
        $maxAge > 0 or die "ERROR: snapshot maximum age is 0! this would delete all your snapshots.\n";
        #check if snapshot is older than the maximum age; removes all snapshots that are older than the maximum time to keep
        if ($snapshotAge > $maxAge){
            push @toDestroy, $snapshot;
            next;
        }
        #calculate timeslot
        my $timeslot = int($snapshotTimestamp / $timePlan->{$maxAge});
        #check if timeslot is already occupied, if so, push this snapshot to the destroy list
        if (exists $timeslots{$maxAge} && exists $timeslots{$maxAge}->{$timeslot}){
            push @toDestroy, $snapshot if $snapshotTimestamp != $time; #make sure, latest snapshot won't be deleted
        }
        else{
            #define timeslot
            $timeslots{$maxAge}->{$timeslot} = 1;
        }
    }
    return \@toDestroy;
}

sub getLastScrubTimestamp {
    my $self = shift;
    my $zpoolStatus = shift;
    my $scrubFilter = $self->scrubFilter;
    my $scrubTimeFilter = $self->scrubTimeFilter;
    my $scrubTimeFormat = $self->scrubTimeFormat;

    for (@$zpoolStatus){
        next if !/$scrubFilter/;

        /($scrubTimeFilter)$/ or die "ERROR: cannot parse last scrub time\n";
        my $scrubTime = Time::Piece->strptime($1, $scrubTimeFormat) or die "ERROR: cannot parse last scrub time\n";

        return $scrubTime->epoch;
    }

    return 0;
}

sub getTimestamp {
    my $self = shift;
    #useUTC flag set?
    my $time = $_[0] ? gmtime : localtime;
    if ($self->timeWarp){
        $time = $time + Time::Seconds->new($self->timeWarp);
    }
    #need to call method seconds as addition will return a Time::Seconds object
    return ($time->epoch + $time->tzoffset)->seconds;
}

sub checkTimeFormat {
    my $self = shift;
    my $timeFormat = shift;

    $timeFormat =~ /^(?:%[YmdHMSz]|[\w\-.:])+$/ or die "ERROR: timestamp format not valid. check your syntax\n";

    #just a made-up timestamp to check if strftime and strptime work
    my $timeToCheck = 1014416542;

    my $formattedTime = $self->createSnapshotTime($timeToCheck, $timeFormat)
        or die "ERROR: timestamp format not valid. check your syntax\n";

    my $resultingTime = $self->$getSnapshotTimestamp("dummydataset\@$formattedTime", $timeFormat)
        or die "ERROR: timestamp format not valid. check your syntax\n";

    return $timeToCheck == $resultingTime; #times schould be equal
}

sub getSnapshotFilter {
    my $self = shift;
    my $timeFormat = shift;

    $timeFormat =~ s/%[mdHMS]/\\d{2}/g;
    $timeFormat =~ s/%Y/\\d{4}/g;
    $timeFormat =~ s/%z/[-+]\\d{4}/g;

    # escape dot ('.') character
    $timeFormat =~ s/\./\\./g;

    return $timeFormat;
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

=head2 useUTC

returns whether UTC or localtime will be used for the given time format

=head2 getInterval

returns the smallest time interval within a backup plan -> this will be the snapshot creation interval

=head2 createSnapshotTime

returns a formatted string from a timestamp and a timestamp format

=head2 getNextSnapshotTimestamp

returns a timestamp when the next action (i.e. snapshot creation) has to be done for a specific backup set

=head2 snapshotsToDestroy

returns a list of snapshots which have to be destroyed according to the backup plan

=head2 getLastScrubTimestamp

extracts the time scrub ran (and finished) last on a pool

=head2 getTimestamp

returns the current timestamp

=head2 checkTimeFormat

checks if a given timestamp format is valid

=head2 getSnapshotFilter

returns a regex pattern to match the snapshot time format

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

