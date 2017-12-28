ZnapZend 0.17.0
===============

[![Build Status](https://travis-ci.org/oetiker/znapzend.svg?branch=master)](https://travis-ci.org/oetiker/znapzend)
[![Coverage Status](https://img.shields.io/coveralls/oetiker/znapzend.svg)](https://coveralls.io/r/oetiker/znapzend?branch=master)
[![Gitter](https://badges.gitter.im/oetiker/znapzend.svg)](https://gitter.im/oetiker/znapzend)

ZnapZend is a ZFS centric backup tool to create snapshots and send them to backup locations. It relies on the ZFS tools snapshot, send and receive to do its work. It has the built-in ability to manage both local
snapshots as well as remote copies by thinning them out as time progresses.

The ZnapZend configuration is stored as properties in the ZFS filesystem
itself.

Compilation Instructions
------------------

You need a compiler and stuff for this to work.

On RedHat you get the necessaries with:

    yum install perl-core

On Ubuntu / Debian with:

    apt-get install perl unzip

On Solaris you may need the c compiler from Solaris Studio and gnu-make
since the installed perl version is probably very old.

On OmniOS/SmartOS you will need perl and gnu-make

with that in place you can now utter:

```sh
wget https://github.com/oetiker/znapzend/releases/download/v0.17.0/znapzend-0.17.0.tar.gz
tar zxvf znapzend-0.17.0.tar.gz
cd znapzend-0.17.0
./configure --prefix=/opt/znapzend-0.17.0
```

If configure finds anything noteworthy, it will tell you about it.  If any
perl modules are found to be missing, they get installed locally into the znapzend
installation. Your perl installation will not get modified!

```sh
make
make install
```

Optionally (but recommended) put symbolic links to the installed binaries in the
system PATH.

```sh
for x in /opt/znapzend-0.17.0/bin/*; do ln -s $x /usr/local/bin; done
```

Debian packages
---------------

Debian control files, guide on using them and experimental debian packages can be found at https://github.com/Gregy/znapzend-debian


Configuration
-------------

For remote backups, znapzend uses ssh. So make sure to configure key based (passwordless) ssh login to the backup target host, so that znapzend is able to connect.

Use `znapzendzetup`to create the desired backup properties within your ZFS pool.

Example:

    znapzendzetup create --recursive\
       --pre-snap-command="/bin/sh /usr/local/bin/lock_flush_db.sh" \
       --post-snap-command="/bin/sh /usr/local/bin/unlock_db.sh" \
       SRC '7d=>1h,30d=>4h,90d=>1d' tank/home \
       DST:a '7d=>1h,30d=>4h,90d=>1d,1y=>1w,10y=>1month' root@bserv:backup/home 

See the [znapzendzetup manual](doc/znapzendzetup.pod) for the full configuration options.

Running
-------

The [znapzend](doc/znapzend.pod) demon is responsible for doing the actual backups.

To see if your configuration is any good, run znapzend in noaction mode first.

```sh
znapzend --noaction --debug
```

If you don't want to wait for the scheduler to actually schedule work, you can also force immediate action by calling

```sh
znapzend --noaction --debug --runonce=<src_dataset>
```

then when you are happy with what you got, start it in daemon mode.

```sh
znapzend --daemonize
```

Best is to integrate znapzend into your system startup sequence, but you can also
run it by hand. See the init/README.md for some inspiration.

Statistics
----------

If you want to know how much space your backups are using, try the
[znapzendztatz](doc/znapzendztatz.pod) utility.

Support and Contributions
-------------------------
If you find a problem with znapzend, please open an Issue on GitHub.

If you like to get in touch, come to [![Gitter](https://badges.gitter.im/oetiker/znapzend.svg)](https://gitter.im/oetiker/znapzend).

And if you have a contribution, please send a pull request.

Enjoy!

Dominik Hassler & Tobi Oetiker
2017-02-08
