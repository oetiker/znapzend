package ZnapZend::Config;

use Mojo::Base -base;
use ZnapZend::ZFS;
use ZnapZend::Time;
use Text::ParseWords qw(shellwords);

### attributes ###
has debug    => sub { 0 };
has noaction => sub { 0 };
has rootExec => sub { q{} };
has timeWarp => sub { undef };
has zLog => sub { Mojo::Exception->throw('zLog must be specified at creation time!') };

#mandatory properties
has mandProperties => sub {
    {
        enabled       => 'on|off',
        recursive     => 'on|off',
        src           => '###dataset###',
        src_plan      => '###backupplan###',
        tsformat      => '###tsformat###',
        pre_znap_cmd  => '###command###',
        post_znap_cmd => '###command###',
    }
};

has zfs  => sub { my $self = shift; ZnapZend::ZFS->new(rootExec => $self->rootExec); };
has time => sub { ZnapZend::Time->new(timeWarp=>shift->timeWarp); };

has backupSets => sub { [] };

### private functions ###
my $splitHostDataSet = sub { return ($_[0] =~ /^(?:([^:]+):)?([^:]+)$/); };

### private methods ###
my $checkBackupPlan = sub {
    my $self = shift;
    my $backupPlan = lc shift;
    my $returnBackupPlan;

    $backupPlan =~ s/\s+//g; #remove all unnecessary whitespaces
    my @planItems = split /,/, $backupPlan;

    for my $planItem (@planItems){
        my @planValues = split /=>/, $planItem, 2;

        my $time = $self->time->checkTimeUnit($planValues[0])
            or die "ERROR: backup plan $backupPlan is not valid\n";

        $returnBackupPlan .= "$time=>";
        $time = $self->time->checkTimeUnit($planValues[1])
            or die "ERROR: backup plan $backupPlan is not valid\n";

        $returnBackupPlan .= "$time,";
    }
    # remove trailing comma
    $returnBackupPlan =~ s/,$//;

    # check if backup plan hash can be built
    $self->time->backupPlanToHash($returnBackupPlan);

    return $returnBackupPlan;
};

my $checkBackupSets = sub {
    my $self = shift;

    for my $backupSet (@{$self->backupSets}){

        # in case there is only one property on this dataset, which is the "enabled" and is set to "off"
        # consider it a normal situation and do not even notify it. This situation will appear
        # when there are descendants of recursive ZFS dataset that should be skipped.
        # Note: backupSets will have at least the key "Src". Therefore, we need to skip the
        # dataset if there are two properties and one of them is "enabled".
        if (keys(%{$backupSet}) eq 2 && exists($backupSet->{"enabled"})){
           next;
        }

        for my $prop (keys %{$self->mandProperties}){
            exists $backupSet->{$prop} || do {
                $self->zLog->info("WARNING: property $prop not set on backup for " . $backupSet->{src} . ". Skipping to next dataset");
                last;
            };
                
            for ($self->mandProperties->{$prop}){
                #check mandatory properties
                /^###backupplan###$/ && do {
                    $backupSet->{$prop} = $self->$checkBackupPlan($backupSet->{$prop});
                    last;
                };
                /^###dataset###$/ && do {
                    $self->zfs->dataSetExists($backupSet->{$prop})
                        or die 'ERROR: filesystem ' . $backupSet->{$prop} . " does not exist\n";
                    last;
                };
                /^###tsformat###$/ && do {
                    $self->time->checkTimeFormat($backupSet->{$prop})
                        or die "ERROR: timestamp format not valid. check your syntax\n";
                    last;
                };
                /^###command###$/ && do {
                    last if $backupSet->{$prop} eq 'off';
                    
                    my $file = (shellwords($backupSet->{$prop}))[0];
                    $self->zfs->fileExistsAndExec($file)
                        or die "ERROR: property $prop: executable '$file' does not exist or can't be executed\n";
                    last;
                };
                #check if properties are valid
                my @values = split /\|/, $self->mandProperties->{$prop}, 2;
                my $value = $backupSet->{$prop};
                grep { /^$value$/ } @values
                    or die "ERROR: property $prop is not valid on dataset " . $backupSet->{src} . "\n";
            }
        }
        #check destination plans and datasets
        for my $dst (grep { /^dst_[^_]+$/ } keys %$backupSet){
            #store backup destination validity. will be checked where used
            $backupSet->{$dst . '_valid'} = $self->zfs->dataSetExists($backupSet->{$dst});

            #if a backup destination is given, we also need a plan
            $backupSet->{$dst . '_plan'} or die "ERROR: no backup plan given for destination\n";

            $backupSet->{$dst . '_plan'} = $self->$checkBackupPlan($backupSet->{$dst . '_plan'});

            # mbuffer property set? check if executable is available on remote host
            if ($backupSet->{mbuffer} ne 'off'){
                my ($mbuffer, $mbufferPort) = split /:/, $backupSet->{mbuffer}, 2;
                my ($remote, $dataset) = $splitHostDataSet->($backupSet->{$dst});
                my $file = ($remote ? "$remote:" : '') . $mbuffer;
                $self->zfs->fileExistsAndExec($file)
                    or warn "*** WARNING: executable '$mbuffer' does not exist" . ($remote ? " on $remote\n\n" : "\n\n");

                #check if mbuffer size is valid
                $backupSet->{mbuffer_size} =~ /^\d+[bkMG%]?$/
                    or die "ERROR: mbuffer size '" . $backupSet->{mbuffer_size} . "' invalid\n";
                #check if port is numeric
                $mbufferPort && do {
                    $mbufferPort =~ /^\d{1,5}$/ && int($mbufferPort) < 65535
                        or die "ERROR: $mbufferPort not a valid port number\n";
                };
            }
        }
        #drop destination plans where destination is not given (e.g. calling create w/o a destination but a plan
        for my $dst (grep { /^dst_[^_]+_plan$/ } keys %$backupSet){
            $dst =~ s/_plan//; #remove trailing '_plan' so we get destination
            
            #remove destination plan if destination is not specified
            exists $backupSet->{$dst} or delete $backupSet->{$dst . '_plan'};
        }
    }
    return 1;
};

my $getBackupSet = sub {
    my $self = shift;
    my $enabledOnly = shift;
    my $dataSet = shift;
    
    #get all backup sets and check if valid
    $self->backupSets($self->zfs->getDataSetProperties($dataSet));
    $self->$checkBackupSets();

    if ($enabledOnly){
        my @backupSets;

        for my $backupSet (@{$self->backupSets}){
            push @backupSets, $backupSet if $backupSet->{enabled} eq 'on';
        }
        #return enabled only backup sets
        return \@backupSets;
    }
    #return all available backup sets
    return $self->backupSets;
};

sub getBackupSet {
    my $self = shift;

    return $self->$getBackupSet(0, @_);
}

sub getBackupSetEnabled {
    my $self = shift;

    return $self->$getBackupSet(1, @_);
}

sub checkBackupSet {
    my $self = shift;
    my $cfg = shift;

    $self->backupSets([$cfg]);
    $self->$checkBackupSets();

    return $self->backupSets->[0];
}

sub setBackupSet {
    my $self = shift;
    my $cfg = shift;
    
    #main program should check backup set prior to set it. anyway, check again just to be sure
    $self->checkBackupSet($cfg);

    #delete existing backup set in case some settings have been removed
    $self->deleteBackupSet($self->backupSets->[0]->{src});

    $self->zfs->setDataSetProperties($self->backupSets->[0]->{src}, $self->backupSets->[0]);

    return 1;
}

sub deleteBackupSet {
    my $self = shift;
    my $dataSet = shift;

    $self->zfs->deleteDataSetProperties($dataSet);

    return 1;
}

sub deleteBackupDestination {
    my $self = shift;
    my $dataSet = shift;
    my $dst = shift;

    $self->zfs->deleteBackupDestination($dataSet, $dst);

    return 1;
}

sub enableBackupSet {
    my $self = shift;
    my $dataSet = shift;

    $self->zfs->dataSetExists($dataSet) or die "ERROR: dataset $dataSet does not exist\n";

    $self->backupSets($self->zfs->getDataSetProperties($dataSet));

    if (@{$self->backupSets}){
        my %cfg = %{$self->backupSets->[0]};
        $cfg{enabled} = 'on';
        $self->setBackupSet(\%cfg);

        return 1;
    }

    return 0;
}

sub disableBackupSet {
    my $self = shift;
    my $dataSet = shift;

    $self->zfs->dataSetExists($dataSet) or die "ERROR: dataset $dataSet does not exist\n";

    $self->backupSets($self->zfs->getDataSetProperties($dataSet));

    if (@{$self->backupSets}){
        my %cfg = %{$self->backupSets->[0]};
        $cfg{enabled} = 'off';
        $self->setBackupSet(\%cfg);

        return 1;
    }

    return 0;
}

1;

__END__

=head1 NAME

ZnapZend::Config - znapzend config class

=head1 SYNOPSIS

use ZnapZend::Config;
...
my $zConfig = ZnapZend::Config->new(\%cfg, noaction => 0, debug => 0);
...

=head1 DESCRIPTION

reads and writes znapzend backup configuration

=head1 ATTRIBUTES

=head2 debug

print debug information to STDERR

=head2 noaction

do a dry run. no changes to the filesystem will be performed

=head2 cfg

keeps the backup configuration to be set

=head1 METHODS

=head2 getBackupSet

returns the backup settings for a dataset or all datasets if dataset is omitted

=head2 getBackupSetEnabled

as getBackupSet but returns only backup sets which are enabled

=head2 checkBackupSet

checks a backup set validity.

=head2 setBackupSet

stores the backup settings (in attribute cfg) to the dataset

=head2 deleteBackupSet

deletes a backup set (does NOT remove snapshots)

=head2 deleteBackupDestination

removes a destination from a backup set

=head2 enableBackupSet

enables a backup set

=head2 disableBackupSet

disables a backup set

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

2014-06-29 had Flexible snapshot time format
2014-06-01 had Multi destination backup
2014-05-30 had Initial Version

=cut

