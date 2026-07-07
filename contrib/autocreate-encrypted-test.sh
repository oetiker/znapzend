#!/bin/bash
#
# Manual real-ZFS integration test for autoCreation with raw (encrypted) sends.
# Companion to contrib/autocreate-test.sh, which covers the unencrypted case.
#
# This is NOT run by the automated test suite (which uses a mocked zfs); it
# needs root and a real ZFS with encryption support. Run it by hand to verify
# that 'znapzend --features=sendRaw --autoCreation' auto-creates the encrypted
# destination datasets. A raw encrypted stream must be received into a dataset
# that 'zfs recv -w' creates itself (so it becomes its own encryption root);
# znapzend therefore must not pre-create it, but must still send to it.

TEST_FILE1=./test1-enc.img
TEST_FILE1_FULL=$(realpath -s "${TEST_FILE1}")
TEST_FILE2=./test2-enc.img
TEST_FILE2_FULL=$(realpath -s "${TEST_FILE2}")
TEST_SIZE=300M

POOL1=test1enc
POOL2=test2enc
ENC=${POOL1}/enc            # encryption root on the source
SUB1=${ENC}/sub1
SUB1_2=${SUB1}/sub2

# Non-interactive passphrase for the encrypted source dataset.
KEYFILE=$(mktemp /tmp/znapzend-enc-key.XXXXXX)
echo "znapzend-test-passphrase" > "${KEYFILE}"

set -x

# (Re)create the source pool with an encrypted dataset tree...
zpool destroy ${POOL1} 2>/dev/null
rm -f "${TEST_FILE1_FULL}"
truncate -s ${TEST_SIZE} "${TEST_FILE1_FULL}"
zpool create ${POOL1} "${TEST_FILE1_FULL}"
zfs create -o encryption=on -o keyformat=passphrase -o keylocation=file://${KEYFILE} ${ENC}
zfs create ${SUB1}
zfs create ${SUB1_2}

# (Re)create the destination pool. Its root stays unencrypted; the received
# datasets carry their own encryption from the raw stream.
zpool destroy ${POOL2} 2>/dev/null
rm -f "${TEST_FILE2_FULL}"
truncate -s ${TEST_SIZE} "${TEST_FILE2_FULL}"
zpool create ${POOL2} "${TEST_FILE2_FULL}"

# znapzend setup: back up the encrypted source tree to a not-yet-existing
# dataset on the destination pool (the pool root exists, the 'enc' leaf does
# not - that is what autoCreation must arrange via the raw receive).
znapzendzetup create --donotask --tsformat='%Y%m%dT%H%M%S' --recursive \
    SRC '1h=>15min,2d=>1h,14d=>1d,3m=>1w' ${ENC} \
    DST:nas '1h=>15min,2d=>1h,14d=>1d,3m=>1w,1y=>1m' ${POOL2}/enc

# Enable autoCreation for this destination (set directly on the source).
zfs set org.znapzend:dst_nas_autocreation=on ${ENC}
zfs get all ${ENC} | grep org.znapzend

# Run znapzend with raw sends + autoCreation...
znapzend --debug --logto=/dev/stdout --features=sendRaw --runonce=${ENC} --autoCreation

set +x

# Verify the destination tree was auto-created and is encrypted...
echo
echo "=== Destination datasets ==="
zfs list -r ${POOL2} || true
echo
RESULT=0
for ds in ${POOL2}/enc ${POOL2}/enc/sub1 ${POOL2}/enc/sub1/sub2 ; do
    if ! zfs list "${ds}" >/dev/null 2>&1 ; then
        echo "FAIL: destination dataset ${ds} was not created"
        RESULT=1
        continue
    fi
    enc=$(zfs get -H -o value encryption "${ds}")
    if [ "${enc}" = "off" ] || [ -z "${enc}" ] ; then
        echo "FAIL: destination dataset ${ds} is not encrypted (encryption=${enc})"
        RESULT=1
    else
        echo "OK:   ${ds} created, encryption=${enc}"
    fi
done

# Clean up the key file; pools/images are left for inspection like the
# companion script.
rm -f "${KEYFILE}"

if [ "${RESULT}" -eq 0 ] ; then
    echo "PASS: raw autoCreation created the encrypted destination tree"
else
    echo "RESULT: one or more checks failed"
fi
exit ${RESULT}
