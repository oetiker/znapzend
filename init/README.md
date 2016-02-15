# Init scripts

## Solaris/Illumos

For solaris/illumos OSes you can import make configure install a znapzend
service manifest by calling configure with the option
```--enable-svcinstall=/var/svc/manifest/site```.  Since the manifest
contains the absolute path the the znapzend install directory, it is not
contained in the prebuilt version.  But you can get a copy from github and
roll your own.

```sh
svccfg validate /var/svc/manifest/site/znapzend.xml
svccfg import /var/svc/manifest/site/znapzend.xml
```

and then enable the service

```sh
svcadm enable oep/znapzend
```

## Systemd

For systemd based systems, you can copy ```znapzend.service``` to ```/etc/systemd/system/``` and then enable and start the daemon.

```sh
systemctl enable znapzend.service
systemctl start znapzend.service
```
