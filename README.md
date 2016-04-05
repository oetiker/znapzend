ZnapZend 0.15.3
===============

[![Build Status](https://travis-ci.org/oetiker/znapzend.svg?branch=master)](https://travis-ci.org/oetiker/znapzend)
[![Coverage Status](https://img.shields.io/coveralls/oetiker/znapzend.svg)](https://coveralls.io/r/oetiker/znapzend?branch=master)

ZnapZend is a ZFS centric backup tool. It relies on snapshot, send and
receive todo its work. It has the built-in ability to manage both local
snapshots as well as remote copies by thining them out as time progresses.

The ZnapZend configuration is stored as properties in the ZFS filesystem
itself.

Zetup Inztructionz
------------------

Follow these zimple inztructionz below to get a custom made copy of
znapzend. 

If you're running a redhat like system, be sure to have Perl's core modules installed :

```sh
yum install perl-core
```

Yes you need a compiler and stuff for this to work.

```sh
wget https://github.com/oetiker/znapzend/releases/download/v0.15.3/znapzend-0.15.3.tar.gz
tar zxvf znapzend-0.15.3.tar.gz
cd znapzend-0.15.3
./configure --prefix=/opt/znapzend-0.15.3
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
for x in /opt/znapzend-0.15.3/bin/*; do ln -s $x /usr/local/bin; done
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

If you like to get in touch, you can find Dominik and Tobi on the IRC-Channel [#znapzend on irc.freenode.net](irc://irc.freenode.net/#znapzend)

And if you have a contribution, please send a pull request.

Enjoy!

Dominik Hassler & Tobi Oetiker
2016-02-25
