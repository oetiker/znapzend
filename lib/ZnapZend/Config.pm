package ZnapZend::Config;

use Mojo::Base -base;
use ZnapZend::ZFS;
use ZnapZend::Time;
use Text::ParseWords qw(shellwords);

### attributes ###
has debug           => sub { 0 };
has lowmemRecurse   => sub { 0 };
has zfsGetType      => sub { 0 };
has noaction        => sub { 0 };
has rootExec        => sub { q{} };
has timeWarp        => sub { undef };
has zLog            => sub {
    my $stack = "";
    for (my $i = 0; my @r = caller($i); $i++) { $stack .= "$r[1]:$r[2] $r[3]\n"; }
    Mojo::Exception->throw('ZConfig::zLog must be specified at creation time!' . "\n$stack" );
};

### mandatory properties ###
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

has zfs  => sub {
    my $self = shift;
    ZnapZend::ZFS->new(
        rootExec => $self->rootExec,
        debug => $self->debug,
        lowmemRecurse => $self->lowmemRecurse,
        zfsGetType => $self->zfsGetType,
        zLog => $self->zLog
    );
};
has time => sub { ZnapZend::Time->new(timeWarp=>shift->timeWarp); };

has backupSets => sub { [] };

### private functions ###
my $splitHostDataSet = sub {
    #return ($_[0] =~ /^(?:([^:\/]+):)?([^:]+|[^:@]+\@.+)$/);
    # See https://github.com/oetiker/znapzend/pull/585
    return ($_[0] =~ /^(?:([^:\/]+):)?([^@\s]+|[^@\s]+\@[^@\s]+)$/);
};

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

        # In case there is only one property on this dataset, which is the
        # "enabled" flag and is set to "off"; consider it a normal situation
        # and do not even notify it. This situation will appear when there
        # are descendants of recursive ZFS dataset that should be skipped.
        # Note: backupSets will have at least the key "src". Therefore, we
        # need to skip the dataset if there are two properties and one of
        # them is "enabled".
        if (keys(%{$backupSet}) eq 2 && exists($backupSet->{"enabled"})){
            next;
        }

        # Similarly for datasets which declare both the "enabled" flag and
        # the "recursion" flag (e.g. to prune whole dataset sub-trees from
        # backing up with znapzend) by configuring only the root of such
        # sub-tree.
        if (keys(%{$backupSet}) eq 3 && exists($backupSet->{"enabled"}) && exists($backupSet->{"recursive"})){
            next;
        }

        if ( $backupSet->{src} =~ m/[\@]/ ) {
            # If we are here, somebody fed us a snapshot in the list of
            # datasets, which is likely a bug elsewhere in discovery.
            # We do not want to fail whole backup below due to faulted
            # dataSetExists() below, so just ignore this entry.
            # If we really do get here, take a hard look at recursive
            # and/or inherited modes for run-once.
            $self->zLog->error( "#checkBackupSets# SKIP backupSet='"
                . $backupSet->{src} ."' because it is not a filesystem,volume. "
                . "BUG: Should not get here.");# if $self->debug;
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

        # mbuffer properties not set for source? legacy behavior was to not use
        # any on the sender, except when in port-to-port mode
        if (!exists($backupSet->{src_mbuffer}) or !($backupSet->{src_mbuffer})) {
            # Have *something* defined to avoid further exists() checks at least
            $backupSet->{src_mbuffer} = undef;
            if ($backupSet->{mbuffer}) {
                if ($backupSet->{mbuffer} eq 'off') {
                    # Only use the setting for source if legacy "off" is set
                    $backupSet->{src_mbuffer} = $backupSet->{mbuffer};
                    $self->zLog->info("WARNING: property 'src_mbuffer' not set on backup for " . $backupSet->{src} . ", inheriting 'off' from legacy 'mbuffer'");
                } else {
                    my ($mbuffer, $mbufferPort) = split /:/, $backupSet->{mbuffer}, 2;
                    #check if port is numeric
                    if ($mbufferPort &&
                        $mbufferPort =~ /^\d{1,5}$/ && int($mbufferPort) < 65535
                    ) {
                        # Only use the setting for source program if the legacy
                        # "/path/to/mbuffer:port" is set (note we would use a
                        # port defined by each destination separately - maybe
                        # inherited from the legacy setting, maybe re-defined
                        # locally or even avoided for that destination link).
                        $backupSet->{src_mbuffer} = $mbuffer;
                        $self->zLog->info("WARNING: property 'src_mbuffer' not set on backup for " . $backupSet->{src} . ", inheriting path from legacy 'mbuffer': " . $backupSet->{src_mbuffer});
                    }
                }
            }
        }
        if ($backupSet->{src_mbuffer}) {
            if (!($self->zfs->fileExistsAndExec($backupSet->{src_mbuffer}))) {
                warn "*** WARNING: executable '$backupSet->{src_mbuffer}' does not exist on source system, will ignore\n\n";
                $backupSet->{src_mbuffer} = undef;
            }
        }
        if (!exists($backupSet->{src_mbuffer_size}) or !($backupSet->{src_mbuffer_size})) {
            $backupSet->{src_mbuffer_size} = $backupSet->{mbuffer_size};
            $self->zLog->info("WARNING: property 'src_mbuffer_size' not set on backup for " . $backupSet->{src} . ", inheriting from legacy 'mbuffer_size': " . $backupSet->{src_mbuffer_size}) if $backupSet->{src_mbuffer_size};
        }

        #check destination plans and datasets
        for my $dst (grep { /^dst_[^_]+$/ } keys %$backupSet){
            #store backup destination validity. will be checked where used
            $backupSet->{$dst . '_valid'} = $self->zfs->dataSetExists($backupSet->{$dst});

            #if a backup destination is given, we also need a plan
            $backupSet->{$dst . '_plan'} or die "ERROR: no backup plan given for destination\n";

            $backupSet->{$dst . '_plan'} = $self->$checkBackupPlan($backupSet->{$dst . '_plan'});

            # mbuffer properties not set for destination? inherit the legacy default ones.
            if (!exists($backupSet->{$dst . '_mbuffer'}) or !($backupSet->{$dst . '_mbuffer'})) {
                ###if ($backupSet->{mbuffer}) {
                    $backupSet->{$dst . '_mbuffer'} = $backupSet->{mbuffer};
                ### Do not preclude inheritance when legacy setting changes
                ###} else {
                ###    $backupSet->{$dst . '_mbuffer'} = 'off';
                ###}
                $self->zLog->info("WARNING: property '" . $dst . "_mbuffer' not set on backup for " . $backupSet->{src} . ", inheriting path[:port] from legacy 'mbuffer': " . $backupSet->{$dst . '_mbuffer'}) if $backupSet->{$dst . '_mbuffer'};
            }
            if (!exists($backupSet->{$dst . '_mbuffer_size'}) or !($backupSet->{$dst . '_mbuffer_size'})) {
                $backupSet->{$dst . '_mbuffer_size'} = $backupSet->{mbuffer_size};
                $self->zLog->info("WARNING: property '" . $dst . "_mbuffer_size' not set on backup for " . $backupSet->{src} . ", inheriting from legacy 'mbuffer_size': " . $backupSet->{$dst . '_mbuffer_size'}) if $backupSet->{$dst . '_mbuffer_size'};
            }

            # mbuffer property set? check if executable is available on remote host
            if ($backupSet->{$dst . '_mbuffer'} ne 'off') {
                my ($mbuffer, $mbufferPort) = split /:/, $backupSet->{$dst . '_mbuffer'}, 2;
                my ($remote, $dataset) = $splitHostDataSet->($backupSet->{$dst});
                my $file = ($remote ? "$remote:" : '') . $mbuffer;
                $self->zfs->fileExistsAndExec($file)
                    or warn "*** WARNING: executable '$mbuffer' does not exist on " . ($remote ? "remote $remote" : "local") . " system, zfs receive can fail\n\n";
                    # TOTHINK: Reset to 'off'/undef and ignore the validity checks below?

                #check if mbuffer size is valid
                $backupSet->{$dst . '_mbuffer_size'} =~ /^\d+[bkMG%]?$/
                    or die "ERROR: mbuffer size '" . $backupSet->{$dst . '_mbuffer_size'} . "' invalid\n";
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
    # The recursion setting allows to find datasets under the named one
    # (e.g. a pool root DS that might not necessarily have a znapzend
    # configuration by itself). Similar to listing ALL configs when no
    # dataset was passed, but no impact of looking at the whole system.
    my $recurse = shift;
    # By default znapzend tools look only at datasets that have their
    # "org.znapzend:*" attributes in a "local" source (so as to not add
    # confusion with local backups that would have such attributes
    # "received" via ZFS replication). This option allows to look also
    # at child datasets that have the backup plan attributes inherited
    # from a dataset that has it defined locally, allowing in particular
    # for quicker "run once" backup re-runs of a small subtree.
    my $inherit = shift;

    # Get all backup sets and check if valid, from remainder of ARGV.
    # If both recurse and inherit are specified, behavior depends on
    # the dataset(s) whose name is passed. If the dataset has a local
    # or inherited-from-local backup plan, the recursion stops here.
    # If it has no plan (e.g. pool root dataset), we should recurse and
    # report all children with a "local" backup plan (ignore inherit).
    if (scalar(@_) > 0) {
        $self->backupSets($self->zfs->getDataSetProperties(\@_, $recurse, $inherit));
    } else {
        # Not that recursion makes much sense for "undef" (=> list everything)
        $self->backupSets($self->zfs->getDataSetProperties(undef, $recurse, $inherit));
    }
    $self->$checkBackupSets();

    printf STDERR "=== getBackupSet() : got "
        . scalar(@{$self->backupSets}) . " dataset(s) with a local "
        . ($inherit ? "or inherited " : "")
        . "backup plan\n"
            if $self->debug;
    # Note/FIXME? If there were ZFS errors getting some of several
    # requested datasets, but at least one succeeded, the result is OK.
    if (scalar(@{$self->backupSets}) == 0) {
        return 0; # false
    }

    if ($enabledOnly){
        my @backupSets;

        for my $backupSet (@{$self->backupSets}){
            push @backupSets, $backupSet if $backupSet->{enabled} eq 'on';
        }
        printf STDERR "=== getBackupSet() : got "
            . scalar(@backupSets) . " enabled-only dataset(s) with a local "
            . ($inherit ? "or inherited " : "")
            . "backup plan\n"
                if $self->debug;
        if (not @backupSets) {
            return 0; # false
        }
        #return enabled only backup sets
        return \@backupSets;
    }
    #return all available backup sets
    return $self->backupSets;
};

### public methods ###
sub getBackupSet {
    my $self = shift;

    # Enforce the $enabledOnly flag (false)
    # Pass the arguments (see the routine definition above for supported list)
    return $self->$getBackupSet(0, @_);
}

sub getBackupSetEnabled {
    my $self = shift;

    # Enforce the $enabledOnly flag (true)
    # Pass the arguments (see the routine definition above for supported list)
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
    my $recurse = shift; # may be undef
    my $inherit = shift; # may be undef

    $self->zfs->dataSetExists($dataSet) or die "ERROR: dataset $dataSet does not exist\n";

    $self->backupSets($self->zfs->getDataSetProperties($dataSet, $recurse, $inherit));

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
    my $recurse = shift; # may be undef
    my $inherit = shift; # may be undef

    $self->zfs->dataSetExists($dataSet) or die "ERROR: dataset $dataSet does not exist\n";

    $self->backupSets($self->zfs->getDataSetProperties($dataSet, $recurse, $inherit));

    if (@{$self->backupSets}){
        my %cfg = %{$self->backupSets->[0]};
        $cfg{enabled} = 'off';
        $self->setBackupSet(\%cfg);

        return 1;
    }

    return 0;
}

sub enableBackupSetDst {
    my $self = shift;
    my $dataSet = shift;
    my $dest = shift;
    my $recurse = shift; # may be undef
    my $inherit = shift; # may be undef

    $self->zfs->dataSetExists($dataSet) or die "ERROR: dataset $dataSet does not exist\n";

    $self->backupSets($self->zfs->getDataSetProperties($dataSet, $recurse, $inherit));

    if (@{$self->backupSets}){
        my %cfg = %{$self->backupSets->[0]};

        if ( !($dest =~ /^dst_[^_]+$/) ) {
            if ($cfg{'dst_' . $dest}) {
                # User passed valid key of the destination config,
                # convert to zfs attribute/perl struct name part
                $dest = 'dst_' . $dest;
            } elsif ($dest =~ /^DST:/) {
                my $desttemp = $dest;
                $desttemp =~ s/^DST:// ;
                if ($cfg{'dst_' . $desttemp}) {
                    # User passed valid key of the destination config,
                    # convert to zfs attribute/perl struct name part
                    $dest = 'dst_' . $desttemp;
                }
            }
            # TODO: Else search by value of 'dst_N' as a "(remote@)dataset"
        }

        if ($cfg{$dest}) {
            if ($cfg{$dest . '_enabled'}) {
                $cfg{$dest . '_enabled'} = undef;
            } else {
                # Already not set => default is "on"
                return 1;
            }
        } else {
            die "ERROR: dataset $dataSet backup plan does not have destination $dest\n";
        }
        $self->setBackupSet(\%cfg);

        return 1;
    }

    return 0;
}

sub disableBackupSetDst {
    my $self = shift;
    my $dataSet = shift;
    my $dest = shift;
    my $recurse = shift; # may be undef
    my $inherit = shift; # may be undef

    $self->zfs->dataSetExists($dataSet) or die "ERROR: dataset $dataSet does not exist\n";

    $self->backupSets($self->zfs->getDataSetProperties($dataSet, $recurse, $inherit));

    if (@{$self->backupSets}){
        my %cfg = %{$self->backupSets->[0]};

        if ( !($dest =~ /^dst_[^_]+$/) ) {
            if ($cfg{'dst_' . $dest}) {
                # User passed valid key of the destination config,
                # convert to zfs attribute/perl struct name part
                $dest = 'dst_' . $dest;
            } elsif ($dest =~ /^DST:/) {
                my $desttemp = $dest;
                $desttemp =~ s/^DST:// ;
                if ($cfg{'dst_' . $desttemp}) {
                    # User passed valid key of the destination config,
                    # convert to zfs attribute/perl struct name part
                    $dest = 'dst_' . $desttemp;
                }
            }
            # TODO: Else search by value of 'dst_N' as a "(remote@)dataset"
        }

        if ($cfg{$dest}) {
            $cfg{$dest . '_enabled'} = 'off';
        } else {
            die "ERROR: dataset $dataSet backup plan does not have destination $dest\n";
        }
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

returns the backup settings for a dataset, it and/or children
if called as recursive, or all datasets if dataset is omitted

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

