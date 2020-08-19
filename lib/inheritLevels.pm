package inheritLevels;
# Note: classes made by Class::Struct may not be sub-namespaced

use Class::Struct;

### Property inheritance levels - how deep we go in routines
### that (need to) care about these nuances beyond a boolean.
### Primarily intended for getSnapshotProperties() to get props
### defined by snapshots of parent datasets with same snapnames.
### For "usual" datasets (filesystem,volume) `zfs` returns the
### properties inherited from higher level datasets; but for
### snapshots it only returns the same - not from higher snaps.
struct ('inheritLevels' => {
    zfs_local => '$', # set to ask for properties defined locally in dataset
    zfs_inherit => '$', # set to ask for properties inherited from higher datasets
    zfs_received => '$', # set to ask for properties received during "zfs send|recv" (no-op for now, mentioned for completeness)
    snapshot_recurse_parent => '$' # "manually" (not via zfs tools) look in same-named snapshots of parent datasets
    } ) ;

    # NOTE that some versions of zfs do not inherit values from same-named
    # snapshot of a parent dataset, but only from a "real" dataset higher
    # in the data hierarchy, so the "-s inherit" argument may be effectively
    # ignored by OS for the purposes of *such* inheritance. Reasonable modes
    # of sourcing properties include:
    #   0 = only local
    #   1 = local + inherit as defined by zfs
    #   2 = local + recurse into parent that has same snapname
    #   3 = local + inherit as defined by zfs + recurse into parent
    # In older code other name-code mappings included:
    #    local_only => 0,
    #    local_zfsinherit => 1,
    #    local_recurseparent => 2,
    #    local_recurseparent_zfsinherit => 3,

sub getInhMode {
    # Method to return a string for "zfs get -s ..." based on the flags in class instance
    my $self = shift;
    my $inhMode = '';
    if ($self->zfs_local) {
        $inhMode .= 'local';
    }
    if ($self->zfs_inherit) {
        if ($inhMode eq '') {
            $inhMode = 'inherited';
        } else {
            $inhMode .= ',inherited';
        }
    }
    if ($self->zfs_received) {
        if ($inhMode eq '') {
            $inhMode = 'received';
        } else {
            $inhMode .= ',received';
        }
    }
    return $inhMode;
}

sub reset {
    # Without args, just resets all fields back to undef so they can be
    # re-assigned later. With an arg tries to import a legacy setting by
    # number or string, or copy from another instance of inheritLevels.
    my $self = shift;
    
    $self->zfs_local(undef);
    $self->zfs_inherit(undef);
    $self->zfs_received(undef);
    $self->snapshot_recurse_parent(undef);
    if (@_) {
        my $arg = shift;
        # Assign from legacy values
        if ($arg->isa('inheritLevels')) {
            $self->zfs_local($arg->zfs_local);
            $self->zfs_inherit($arg->zfs_inherit);
            $self->zfs_received($arg->zfs_received);
            $self->snapshot_recurse_parent($arg->snapshot_recurse_parent);
        } elsif ($arg == 0 or $arg eq 'local_only' or $arg eq 'zfs_local') {
            $self->zfs_local(1);
        } elsif ($arg == 1 or $arg eq 'local_zfsinherit') {
            $self->zfs_local(1);
            $self->zfs_inherit(1);
        } elsif ($arg == 2 or $arg eq 'local_recurseparent') {
            $self->zfs_local(1);
            $self->snapshot_recurse_parent(1);
        } elsif ($arg == 3 or $arg eq 'local_recurseparent_zfsinherit') {
            $self->zfs_local(1);
            $self->snapshot_recurse_parent(1);
            $self->zfs_inherit(1);
        } elsif (!defined($arg) or $arg == undef) {
            1; # No-op, keep fields undef
        } else {
            warn "inheritLevels::reset() got unsupported argument '$arg'\n";
            return 0;
        }
    }
    return 1;
}

1;

__END__

=head1 NAME

inheritLevels - helper struct for various options of ZFS property inheritance

=head1 SYNOPSIS

use inheritLevels;
use ZnapZend::ZFS;
...
my $inherit = new inheritLevels;
$inherit->zfs_local(1);
$inherit->zfs_inherit(1);
my $properties = $self->getSnapshotProperties($snapshot, $recurse, $inherit, @dstSyncedProps);
...

=head1 DESCRIPTION

this object makes zfs property request inheritance settings easier to use

currently used by ZnapZend::ZFS routines getSnapshotProperties and
mostRecentCommonSnapshot but not really useful for getDataSetProperties
so not yet utilized there

=head1 ATTRIBUTES

=head2 zfs_local

ask for values defined locally in a dataset or snapshot itself

=head2 zfs_inherit

ask for values defined in parents of dataset or snapshot itself
as reported by "zfs get" command on the current system; this may
not include values defined in snapshots of a parent dataset's that
are named same as the snapshot you are requesting properties of

=head2 zfs_received

ask for values defined by receiving a dataset or snapshot
by "zfs send|zfs recv"

(zfs_received is not currently used by znapzend but may have
some meaning in the future)

=head2 snapshot_recurse_parent

meaningful only for requests of properties of snapshots: recursively
ask for values defined locally in a same-named snapshot of a parent
or a further ancestor dataset

=head1 COPYRIGHT

Copyright (c) 2020 by OETIKER+PARTNER AG. All rights reserved.

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

S<Jim Klimov E<lt>jimklimov@gmail.comE<gt>>,
S<Tobias Oetiker E<lt>tobi@oetiker.chE<gt>>
