# About

This is a simple bash script that encapsulates `mysqlbinlog` utility to backup and compress binlog files. 

# Features

- Live backup of binlogs (handled by `mysqlbinlog` already)
- Compression of backup files
- Rotation of backup files

# Usage

Clone the repository and run:

```
chmod +x syncbinlog.sh
./syncbinlog.sh --help
```

This will output:

```
Usage: syncbinlog.sh [options]
    Starts live binlog sync using mysqlbinlog utility

  --backup-dir=        Backup destination directory (required)
  --log-dir=           Log directory (defaults to '/var/log/syncbinlog')
  --prefix=            Backup file prefix (defaults to 'backup-')
  --mysql-conf=        Mysql defaults file for client auth (defaults to './.my.cnf')
  --compress           Compress backuped binlog files
  --compress-app=      Compression app (defaults to 'pigz -p{number-of-cores - 1}'). Compression parameters can be given as well (e.g. pigz -p6 for 6 threaded compression)
  --rotate=X           Rotate backup files for X days (defaults to 30)
  --verbose=           Write logs to stdout as well
```

Example: Backup binlog files of last 10 days and compress them

`./syncbinlog.sh --backup-dir=/mnt/backup --prefix="mybackup-" --compress --rotate=10`

# Notes

- In a production database server, it should be controlled by a process manager such as `systemd` or `supervisord` to have more reliable start/restart behaviour.
- `mysqlbinlog` utility copies the binlog files in real-time, however compression is only applied for files older than the one being written at the time. This happens when: 
    - Mysql flushes the log files after a certain time or certain file size. (See `expire_logs_days` and `max_binlog_size`)
    - `FLUSH LOGS` is executed manually or by mysqldump etc. 
- `mysqlbinlog` utility requires the user to have `REPLICATION SLAVE` privilege

# Resources

Some useful resources about binlog backup and point-in-time-recovery:

- https://www.percona.com/blog/2012/01/18/backing-up-binary-log-files-with-mysqlbinlog/
- https://www.percona.com/blog/2017/10/23/mysql-point-in-time-recovery-right-way/
- http://mysqlnoob.blogspot.com/2016/12/in-place-transparent-compression-of-mysql-binary.logs.html
- https://lefred.be/content/howto-make-mysql-point-in-time-recovery-faster/

# License

MIT