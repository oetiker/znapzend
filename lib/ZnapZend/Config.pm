package ZnapZend::Config;

use Mojo::Base -base;
use ZnapZend::ZFS;
use ZnapZend::Time;

### attributes ###
has debug => sub { 0 };
has noaction => sub { 0 };

#mandatory properties
has mandProperties => sub {
    {
        enabled     => 'on|off',
        recursive   => 'on|off',
        src         => '###dataset###',
        src_plan    => '###backupplan###',
        tsformat    => '###tsformat###',
    }
};

has zfs  => sub { ZnapZend::ZFS->new(); };
has time => sub { ZnapZend::Time->new(); };

has backupSets => sub { [] };

has cfg => sub { {} };

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

        (my $time = $self->time->checkTimeUnit($planValues[0])) or die "ERROR: backup plan $backupPlan is not valid\n";
        $returnBackupPlan .= "$time=>";
        ($time = $self->time->checkTimeUnit($planValues[1])) or die "ERROR: backup plan $backupPlan is not valid\n";

        $returnBackupPlan .= "$time,";
    }
    # remove trailing comma
    $returnBackupPlan =~ s/,$//;

    return $returnBackupPlan;
};

my $checkBackupSets = sub {
    my $self = shift;

    for my $backupSet (@{$self->backupSets}){
        for my $prop (keys $self->mandProperties){
            die "ERROR: property $prop not set on backup for " . $backupSet->{src} . "\n" if !exists $backupSet->{$prop};

            for ($self->mandProperties->{$prop}){
                #check mandatory properties
                /^###backupplan###$/ && do {
                    $backupSet->{$prop} = $self->$checkBackupPlan($backupSet->{$prop});
                    last;
                };
                /^###dataset###$/ && do {
                    $self->zfs->dataSetExists($backupSet->{$prop}) or die 'ERROR: filesystem ' . $backupSet->{$prop} . " does not exist\n";
                    last;
                };
                /^###tsformat###$/ && do {
                    $self->time->checkTimeFormat($backupSet->{$prop}) or die "ERROR: timestamp format not valid. check your syntax\n";
                    last;
                };
                #check if properties are valid
                my @values = split /\|/, $self->mandProperties->{$prop}, 2;
                my $value = $backupSet->{$prop};
                die "ERROR: property $prop is not valid on dataset " . $backupSet->{src} . "\n" if !(grep { /^$value$/ } @values);
            }
        }
        #check destination plans and datasets
        for my $dst (grep { /^dst_[^_]+$/ } (keys %{$self->cfg})){
            $self->zfs->dataSetExists($backupSet->{$dst}) or die 'ERROR: filesystem ' . $backupSet->{$dst} . " does not exist\n";
            $backupSet->{$dst . '_plan'} = $self->$checkBackupPlan($backupSet->{$dst . '_plan'});

            # mbuffer property set? check if executable is available on remote host
            if ($backupSet->{mbuffer} ne 'off'){
                my ($remote, $dataset) = $splitHostDataSet->($backupSet->{$dst});
                my $file = ($remote ? "$remote:" : '') . $backupSet->{mbuffer};
                $self->zfs->fileExistsAndExec($file) or die "ERROR: executable '" . $backupSet->{mbuffer} . "' does not exist on $remote\n";
            }
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
    my $dataSet = shift;

    #check if source dataset exists and if source backup plan is valid
    $self->zfs->dataSetExists($dataSet) or die "ERROR: filesystem $dataSet does not exist\n";
    $self->cfg->{src_plan} = $self->$checkBackupPlan($self->cfg->{src_plan}) or die "ERROR: src backup plan not valid\n";
    $self->time->checkTimeFormat($self->cfg->{tsformat}) or die "ERROR:  timestamp format not valid. check your syntax\n"; 

    #check if destination datasets exist anf if destination backup plans are valid
    for my $dst (grep { /^dst_[^_]+$/ } (keys %{$self->cfg})){
        $self->zfs->dataSetExists($self->cfg->{$dst}) or die 'ERROR: filesystem ' . $self->cfg->{$dst} . " does not exist\n";
        $self->cfg->{$dst. '_plan'} = $self->$checkBackupPlan($self->cfg->{$dst . '_plan'}) or die "ERROR: dst backup plan not valid\n";

        if ($self->cfg->{mbuffer} ne 'off'){
            # property set. check if executable is available on remote host
            my ($remote, $dataset) = $splitHostDataSet->($self->cfg->{$dst});
            my $file = ($remote ? "$remote:" : '') . $self->cfg->{mbuffer};
            $self->zfs->fileExistsAndExec($file) or die "ERROR: executable '" . $self->cfg->{mbuffer} . "' does not exist on $remote\n";
        }
    }

    return $self->cfg;
}

sub setBackupSet {
    my $self = shift;
    my $dataSet = shift;
    
    #main program should check backup set prior to set it. anyway, check again just to be sure
    $self->checkBackupSet($dataSet);

    $self->zfs->setDataSetProperties($dataSet, $self->cfg);

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

    die "ERROR: dataset $dataSet does not exist\n" if !$self->zfs->dataSetExists($dataSet);

    $self->backupSets($self->zfs->getDataSetProperties($dataSet));

    if (@{$self->backupSets}){
        $self->cfg(${$self->backupSets}[0]);
        $self->cfg->{enabled} = 'on';
        $self->setBackupSet($dataSet);

        return 1;
    }

    return 0;
}

sub disableBackupSet {
    my $self = shift;
    my $dataSet = shift;

    die "ERROR: dataset $dataSet does not exist\n" if !$self->zfs->dataSetExists($dataSet);

    $self->backupSets($self->zfs->getDataSetProperties($dataSet));

    if (@{$self->backupSets}){
        $self->cfg(${$self->backupSets}[0]);
        $self->cfg->{enabled} = 'off';
        $self->setBackupSet($dataSet);

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
S<Dominik Hassler>

=head1 HISTORY

2014-06-29 had Flexible snapshot time format
2014-06-01 had Multi destination backup
2014-05-30 had Initial Version

=cut

