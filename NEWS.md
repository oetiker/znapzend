# Release Notes

## Version 0.20.0 / 2020-03-23

### New Features

* build system switched to carton for better dependency tracking

* docker version available in `oetiker/znapzend:master` see README.md for details

* `--recursive` option for run-once datasets.

* `--inherited` allow run-once on datasets with only an inherited plan.

* `--focedSnapshotSuffix=x` for non generated snapshot suffix in run-once.

* `--nodelay` temporarily ignore delays in backup plans for speedy debugging.

* new `--features`

    * `sendRaw` to NOT decrypt datasets prior to sending
    * `skipIntermediates` do not send intermediate snapshots
    * `lowmemRecurse` trade memory for speed when running large recursive jobs
    * `zfsGetType` speed up recursive dataset handling ... see znapzend manual page for details.

* znapzendzetup supports `--features` too

* new options for znapzendztatz: `--inherited` and `--setup`


