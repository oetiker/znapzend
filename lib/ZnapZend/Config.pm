package ZnapZend::Config;

use Mojo::Base -base;
use ZnapZend::ZFS;
use ZnapZend::Time;

### attributes ###
has debug => sub { 0 };
has noaction => sub { 0 };

has properties => sub {
    {
        enabled => 'on|off',
        recursive => 'on|off',
        mbuffer => '###executable###',
        src => '###dataset###',
        dst => '###dataset###',
        src_plan => '###backupplan###',
        dst_plan => '###backupplan###',
    }
};

has zfs => sub { ZnapZend::ZFS->new(); };
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
        for my $prop (keys $self->properties){
            die "ERROR: property $prop not set on backup for " . $backupSet->{src} . "\n" if not exists $backupSet->{$prop};

            for ($self->properties->{$prop}){
                /^###backupplan###$/ && do {
                    $backupSet->{$prop} = $self->$checkBackupPlan($backupSet->{$prop});
                    last;
                };
                /^###dataset###$/ && do {
                    $self->zfs->dataSetExists($backupSet->{$prop}) or die 'ERROR: filesystem ' . $backupSet->{$prop} . " does not exist\n";
                    last;
                };
                /^###executable###$/ && do {
                    # property not set. that's ok
                    $backupSet->{$prop} eq 'off' and last;
                    # property set. check if executable is available on remote host
                    my ($remote, $dataset) = $splitHostDataSet->($backupSet->{dst});
                    my $file = ($remote ? "$remote:" : '') . $backupSet->{$prop};
                    $self->zfs->fileExistsAndExec($file) or die "ERROR: executable '" . $backupSet->{$prop} . "' does not exist on $remote\n";
                    last;
                };
                my @values = split /\|/, $self->properties->{$prop}, 2;
                my $value = $backupSet->{$prop};
                die "ERROR: property $prop is not valid on dataset " . $backupSet->{src} . "\n" if not ( grep { /^$value$/ } @values);
            }
        }
    }
    return 1;
};


my $getBackupSet = sub {
    my $self = shift;
    my $enabledOnly = shift;
    my $dataSet = shift;
    
    $self->backupSets($self->zfs->getDataSetProperties($dataSet));
    if ($enabledOnly){
        for (my $i = $#{$self->backupSets}; $i >= 0; $i--){
            splice @{$self->backupSets}, $i, 1 if ${$self->backupSets}[$i]->{enabled} ne 'on';
        }
    }
    $self->$checkBackupSets();
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

sub setBackupSet {
    my $self = shift;
    my $dataSet = shift;

    $self->zfs->dataSetExists($dataSet) or die "ERROR: filesystem $dataSet does not exist\n";
    $self->zfs->dataSetExists($self->cfg->{dst}) or die 'ERROR: filesystem ' . $self->cfg->{dst} . " does not exist\n";
    $self->cfg->{src_plan} = $self->$checkBackupPlan($self->cfg->{src_plan}) or die "ERROR: src backup plan not valid\n";
    $self->cfg->{dst_plan} = $self->$checkBackupPlan($self->cfg->{dst_plan}) or die "ERROR: dst backup plan not valid\n";

    if ($self->cfg->{mbuffer} ne 'off'){
        # property set. check if executable is available on remote host
        my ($remote, $dataset) = $splitHostDataSet->($self->cfg->{dst});
        my $file = ($remote ? "$remote:" : '') . $self->cfg->{mbuffer};
        $self->zfs->fileExistsAndExec($file) or die "ERROR: executable '" . $self->cfg->{mbuffer} . "' does not exist on $remote\n";
    }

    $self->zfs->setDataSetProperties($dataSet, $self->cfg);
    return 1;
}

sub deleteBackupSet {
    my $self = shift;
    my $dataSet = shift;

    $self->zfs->deleteDataSetProperties($dataSet);
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

=head2 setBackupSet

stores the backup settings (in attribute cfg) to the dataset

=head2 deleteBackupSet

deletes a backup set (does NOT remove snapshots)

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

2014-05-30 had Initial Version

=cut

