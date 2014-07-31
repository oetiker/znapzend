ZnapZend 0.8.8
==============

[![Build Status](https://travis-ci.org/oetiker/znapzend.svg?branch=master)](https://travis-ci.org/oetiker/znapzend)
[![Coverage Status](https://img.shields.io/coveralls/oetiker/znapzend.svg)](https://coveralls.io/r/oetiker/znapzend?branch=master)

ZnapZend is a ZFS centric backup tool. It relies on snapshot, send and
receive todo its work. It has the built-in ability to to manage both local
snapshots as well as remote copies by thining them out as time progresses.

The ZnapZend configuration is stored as properties in the ZFS filesystem
itself.

Zetup Zimple
------------

There are two ways to get going with znapzend. You can take the simple way
out and download our prebuilt release.  It comes with all the perlmodules
required for running znapzend with a copy of perl as old as 5.10.1:

```sh
wget https://github.com/oetiker/znapzend/releases/download/v0.8.8/znapzend-prebuilt-0.8.8.tar.gz
tar zxvf znapzend-prebuilt-0.8.8.tar.gz
cp -rp znapzend-prebuilt-0.8.8 /opt/znapzend-0.8.8
```

Read on in the [Configuration](#configuration) Section.

Zetup for Power Admins
----------------------

On the other hand if you are the proud owner of a properly setup unix box
with all the tools and trimmings for building stuff, follow these zimple
inztructionz below to get a cusom made copy of znapzend.

```sh
wget https://github.com/oetiker/znapzend/releases/download/v0.8.8/znapzend-0.8.8.tar.gz
tar zxvf znapzend-0.8.8.tar.gz
cd znapzend-0.8.8
./configure --prefix=/opt/znapzend-0.8.8
```
if configure complains about missing perl modules, run

```sh
./setup/build-thirdparty.sh /opt/znapzend-0.8.8/thirdparty
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
/opt/znapzend-0.8.8/bin/znapzend --noaction --debug
```

If you don't want to wait for the scheduler to actually schedule work, you can also force immediate action by calling

```sh
/opt/znapzend-0.8.8/bin/znapzend --noaction --debug --runonce=<src_dataset>
``` 

then when you are happy with what you got, start it in daemon mode.

```sh
/opt/znapzend-0.8.8/bin/znapzend --daemonize
```
 
Best is to integrate znapzend into your system startup sequence, but you can also
run it by hand.

For illumos OSes you can import the znapzend service manifest provided in the install directory:

```sh
svccfg validate /opt/znapzend-0.8.8/init/znapzend.xml
svccfg import /opt/znapzend-0.8.8/init/znapzend.xml
```

and then enable the service 

```sh
svcadm enable oep/znapzend
```

Statistics
----------

If you want to know how much space your backups are using, try the [znapzendztatz](doc/znapzendztatz.pod) utility.


Enjoy!

Dominik Hassler & Tobi Oetiker
2014-07-30
