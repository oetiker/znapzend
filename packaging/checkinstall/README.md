Create Package
--------------

You can create a package to install (useful for multiple hosts) with _checkinstall_. Best practice is to to this somewhere outside _/home_ (e.g.  _/tmp_ ) or you'll get prompted if you'd like to include/exclude files.

```sh
cd /tmp/
git clone https://github.com/oetiker/znapzend
# git checkout 0.xx.yy
packaging/checkinstall/checkinstall.sh
```
