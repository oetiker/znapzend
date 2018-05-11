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

For macOS launchd, you can create an ```org.oetiker.znapzend.plist```
file in ```/Library/LaunchDaemons``` and then start the daemon with:

```sh
launchctl load /Library/LaunchDaemons/org.oetiker.znapzend.plist
```

```Note:``` It is recommended to ```not``` set the ```--daemonize``` flag of ```znapzend```
as launchd will lose control of the process.  Here are recommended launchd keys to include to
startup at system startup and restart after 30 seconds if znapzend exits (except on crashes).  Substitute the correct program prefix for ${prefix} in the example below:

```sh
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>${prefix}/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
	</dict>
	<key>KeepAlive</key>
	<dict>
		<key>Crashed</key>
		<false/>
	</dict>
	<key>Label</key>
	<string>org.oetiker.znapzend</string>
	<key>ProgramArguments</key>
	<array>
		<string>${prefix}/org.oetiker.znapzend</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StandardErrorPath</key>
	<string>/var/log/org.oetiker.znapzend.stderr</string>
	<key>StandardOutPath</key>
	<string>/var/log/org.oetiker.znapzend.stdout</string>
	<key>ThrottleInterval</key>
	<integer>30</integer>
</dict>
</plist>
```

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
