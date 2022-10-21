#!/usr/bin/env bash

# Help test chosen regex for splitHostDataSet()
# (C) 2022 by Jim Klimov

# https://github.com/oetiker/znapzend/issues/585
#RE='/^(?:(.+)\s)?([^\s]+)$/'
RE='/^(?:([^:\/]+):)?([^:]+|[^:@]+\@.+)$/'

echo 'NOTE: For each probe this should return an array with two strings:'
echo '      empty "", "remotehost" or "user@remotehost" as applicable,'
echo '      and the dataset(@snapshot) name'
#    "root@host -p 22 -id /tmp/key rpool@snaptime-12:34:56" \
for S in \
    "rpool/zones/nut/jenkins-worker/ROOT/openindiana-20220315-backup-1" \
    "rpool/zones/nut/jenkins-worker/ROOT/openindiana-20220315-backup-1@snap" \
    "rpool/zones/nut/jenkins-worker/ROOT/openindiana-20220315-backup-1@snaptime-12:34:56" \
    "rpool/zones/nut/jenkins-worker/ROOT/openindiana-2022:03:15-backup-1" \
    "rpool/zones/nut/jenkins-worker/ROOT/openindiana-2022:03:15-backup-1@snap" \
    "rpool/zones/nut/jenkins-worker/ROOT/openindiana-2022:03:15-backup-1@snaptime-12:34:56" \
    "remotehost:pond/data/set" \
    "remotehost:pond/data/set@snap" \
    "remotehost:pond/data/set@snaptime-12:34:56" \
    "remotehost:pond/data/set/openindiana-2022:03:15-backup-1" \
    "remotehost:pond/data/set/openindiana-2022:03:15-backup-1@snap" \
    "remotehost:pond/data/set/openindiana-2022:03:15-backup-1@snaptime-12:34:56" \
    "user@remotehost:pond/data/set" \
    "user@remotehost:pond/data/set@snap" \
    "user@remotehost:pond/data/set@snaptime-12:34:56" \
    "user@remotehost:pond/data/set/openindiana-2022:03:15-backup-1" \
    "user@remotehost:pond/data/set/openindiana-2022:03:15-backup-1@snap" \
    "user@remotehost:pond/data/set/openindiana-2022:03:15-backup-1@snaptime-12:34:56" \
; do
    perl -e 'print STDERR "[D] Split \"" . $ARGV[0] . "\" into:\n\t[\"" . join("\", \"", ($ARGV[0] =~ '"$RE"')) . "\"]\n";' "$S"
done

