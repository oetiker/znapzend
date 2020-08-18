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

