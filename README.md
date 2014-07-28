ZnapZend 0.8.0
==============

[![Build Status](https://travis-ci.org/oetiker/znapzend.svg?branch=master)](https://travis-ci.org/oetiker/znapzend)
[![Coverage Status](https://img.shields.io/coveralls/oetiker/znapzend.svg)](https://coveralls.io/r/oetiker/znapzend?branch=master)

ZnapZend is a ZFS centric backup tool. It relies on snapshot, send and
receive todo its work. It has the built-in ability to to manage both local
snapshots as well as remote copies by thining them out as time progresses.

The ZnapZend configuration is stored as properties in the ZFS filesystem
itself.

Zetup
-----

To zetup znapzend follow these zimple inztructionz

```sh
wget https://github.com/oetiker/znapzend/releases/download/v0.8.0/znapzend-0.8.0.tar.gz
tar zxvf znapzend-0.8.0.tar.gz
cd znapzend-0.8.0
./configure --prefix=/opt/znapzend-0.8.0
```
if configure complains about missing perl modules, run

```sh
./setup/build-thirdparty.sh /opt/znapzend-0.8.0/thirdparty
```

to install the missing modules into the specified directry. This will NOT messup your local perl installation!

Now you can run configure again and then

```sh
make install
```

Configuration
-------------

Use the [znapzendzetup](doc/znapzendzetup.pod) program to define your backup settings. For remote backup, znapzend uses ssh.
Make sure to configure password free login for ssh to the backup target host.

Running
-------

The [znapzend](doc/znapzend.pod) demon is responsible for doing the actual backups. 

To see if your configuration is any good, run znapzend in noaction mode first.

```sh
znapzend --noaction --debug
```

then when you are happy with what you got, start it in daemon mode.

```sh
znapzend --daemon
```
 
Best is to integrate znapzend into your system startup sequence, but you can also
run it by hand.

Statistics
----------

If you want to know how much space your backups are using, try the [znapzendztatz](doc/znapzendztatz.pod) utility.


Enjoy!

Dominik Hassler & Tobi Oetiker
2014-07-26
