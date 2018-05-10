# Init scripts

This directory includes integration for different service management
frameworks, so that ```znapzend``` works for you automatically (as
long as you have set up the dataset retention policies with the
```znapzendzetup``` utility).

Since the service manifests contain the absolute path to the
```znapzend``` install directory, they are not contained in the
prebuilt version.  But you can get a copy from github and roll
your own by building the project properly or by just manually
replacing the tags in the corresponding ```.in``` template file
to match your existing system layout (replace ```@exec_prefix@```
usually with ```/usr/local``` to match other setup documentation).

## macOS launchd

For macOS launchd, you can copy the generated ```org.oetiker.znapzend.plist```
file to ```/Library/LaunchDaemons``` and then start the daemon with:

```sh
launchctl load /Library/LaunchDaemons/org.oetiker.znapzend.plist
```

```Note:``` It is recommended to ```not``` set the ```--daemonize``` flag of ```znapzend```
as launchd will lose control of the process.

## Solaris/Illumos

For solaris/illumos OSes you can tell configure to install a znapzend
service manifest into a partcular location (no default imposed) by
calling configure with the option like
```--enable-svcinstall=/var/svc/manifest/site```.
You can also define the service name (defaults to ```oep/znapzend```)
by calling configure with the option like
```--with-svcname-smf=system/filesystem/zfs/znapzend```.

After you have installed the manifest file, verify and import it:

```sh
svccfg validate /var/svc/manifest/site/znapzend.xml
svccfg import /var/svc/manifest/site/znapzend.xml
```

and then enable the service

```sh
svcadm enable oep/znapzend
```

## Systemd

For systemd based systems, you can copy the generated ```znapzend.service```
file to ```/etc/systemd/system/``` and then enable and start the daemon.

```sh
systemctl enable znapzend.service
systemctl start znapzend.service
```

## Upstart

For upstart based systems, you can copy the generated ```znapzend.upstart```
file to ```/etc/init/znapzend.conf``` and start the daemon.

```sh
service znapzend start
```
