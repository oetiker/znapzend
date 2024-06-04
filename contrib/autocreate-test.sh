#!/bin/bash

TEST_FILE1=./test1.img
TEST_FILE1_FULL=$(realpath -s "${TEST_FILE1}")
TEST_FILE2=./test2.img
TEST_FILE2_FULL=$(realpath -s "${TEST_FILE2}")
TEST_SIZE=300M

POOL1=test1
SUB1=${POOL1}/sub1
SUB1_2=${SUB1}/sub2
SUB2=${POOL1}/sub2
POOL2=test2

set -x

# Pool creation...
zpool destroy ${POOL1}
rm -f "${TEST_FILE1_FULL}"
truncate -s ${TEST_SIZE} "${TEST_FILE1_FULL}"
zpool create ${POOL1} "${TEST_FILE1_FULL}"
zfs create ${SUB1}
zfs create ${SUB1_2}
zfs create ${SUB2}

zpool destroy ${POOL2}
rm -f "${TEST_FILE2_FULL}"
truncate -s ${TEST_SIZE} "${TEST_FILE2_FULL}"
zpool create ${POOL2} "${TEST_FILE2_FULL}"

# Znapzend setup...
znapzendzetup create --donotask --tsformat='%Y%m%dT%H%M%S' --recursive SRC '1h=>15min,2d=>1h,14d=>1d,3m=>1w' test1 DST:nas '1h=>15min,2d=>1h,14d=>1d,3m=>1w,1y=>1m' test2

# Try the new autoCreation property...
znapzendzetup enable-dst-autocreation ${POOL1} nas

# Output zfs properties...
zfs get all ${POOL1} | grep org.znapzend

# Manually set the property since it doesn't work from znapzendzetup.
# TODO: Remove this after verifying https://github.com/oetiker/znapzend/pull/657 fixes this...
zfs set org.znapzend:dst_nas_autocreation=on ${POOL1}

# Output zfs properties...
zfs get all ${POOL1} | grep org.znapzend

# Znapzend test...
znapzend --debug --logto=/dev/stdout --runonce=${POOL1} --autoCreation

# Output datasets...
zfs list -r ${POOL1} ${POOL2}
