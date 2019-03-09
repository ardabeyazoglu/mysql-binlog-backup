# About

This is just a simple bash script that encapsulates `mysqlbinlog` utility to backup binlog files in real-time. 

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

   --backup-dir      Backup destination directory (required)
   --log-dir         Log directory (defaults to '/var/log/syncbinlog')
   --prefix          Backup file prefix (defaults to 'backup-')
   --mysql-conf      Mysql defaults file for client auth (defaults to './.my.cnf')
   --verbose         Write logs to stdout as well
```

#### Daemonize

In a production database server, it should be daemonized with `systemd` or a process manager like `supervisord`.