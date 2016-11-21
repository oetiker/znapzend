Create Debian/Ubuntu Packages
--------------

You can create a package to install (useful for multiple hosts) with _checkinstall_.

```sh
cd /tmp/
git clone https://github.com/oetiker/znapzend
# git checkout 0.xx.yy
cd znapzend
packaging/checkinstall/checkinstall.sh
```
