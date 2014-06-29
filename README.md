ZnapZend 0.6.0
--------------

[![Build Status](https://travis-ci.org/oetiker/znapzend.svg?branch=master)](https://travis-ci.org/oetiker/znapzend)
[![Coverage Status](https://img.shields.io/coveralls/oetiker/znapzend.svg)](https://coveralls.io/r/oetiker/znapzend?branch=master)

ZnapZend is a ZFS centric backup tool. It relies on snapshot, send and
receive todo its work. It has the built-in ability to to manage both local
snapshots as well as remote copies by thining them out as time progresses.

The ZnapZend configuration is stored as properties in the ZFS filesystem
itself.

To zetup znapzend follow these zimple inztructionz

```sh
wget https://github.com/oetiker/znapzend/releases/download/v0.6.0/znapzend-0.6.0.tar.gz
tar zxvf znapzend-0.6.0.tar.gz
cd znapzend-0.6.0
./configure --prefix=/opt/znapzend-0.6.0
```
if configure complains about missing perl modules, run

```sh
./setup/build-thirdparty.sh /opt/znapzend-0.6.0/thirdparty
```

now you can run configure again and then

```sh
make install
```

now you can configure the thing with the znapzendzetup program

Enjoy!

Dominik Hassler & Tobi Oetiker
2014-06-29
