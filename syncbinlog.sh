#!/bin/bash

################ syncbinlog.sh ##################
# Copyright 2019 Arda Beyazoglu
# MIT License
#
# A simple bash script that uses mysqlbinlog
# utility to syncronize binlog files
#################################################

# Write usage
usage() {
    echo -e "Usage: $(basename $0) [options]"
    echo -e "\tStarts live binlog sync using mysqlbinlog utility\n"
    echo -e "   --backup-dir      Backup destination directory (required)"
    echo -e "   --log-dir         Log directory (defaults to '/var/log/syncbinlog')"
    echo -e "   --prefix          Backup file prefix (defaults to 'backup-')"
    echo -e "   --mysql-conf      Mysql defaults file for client auth (defaults to './.my.cnf')"
    echo -e "   --verbose         Write logs to stdout as well"
    exit 1
}

# Write log
log () {
    local level="INFO"
    if [[ -n $2 ]]; then
        level=$2
    fi
    local msg="[$(date +'%Y-%m-%d %H:%M:%S')][${level}] $1"
    echo "${msg}" >> "${LOG_DIR}/status.log"

    if [[ ${VERBOSE} ]]; then
        echo "${msg}"
    fi
}

# Exit safely on signal
die() {
    log "Exit signal caught!"
    log "Stopping child processes before exit"
    trap - SIGINT SIGTERM # clear the listener
    kill -- -$$ # Sends SIGTERM to child/sub processes
    kill ${APP_PID}
}

# listen to the process signals
trap die SIGINT SIGTERM

# Default configuration parameters
MYSQL_CONFIG_FILE=./.my.cnf
BACKUP_DIR=""
LOG_DIR=/var/log/syncbinlog
BACKUP_PREFIX="backup-"

# Parse configuration parameters
for arg in "$@"
do
case ${arg} in
    --prefix=*)
    BACKUP_PREFIX="${arg#*=}"
    ;;
    --log-dir=*)
    LOG_DIR="${arg#*=}"
    ;;
    --backup-dir=*)
    BACKUP_DIR="${arg#*=}"
    ;;
    --mysql-conf=*)
    MYSQL_CONFIG_FILE="${arg#*=}"
    ;;
    --verbose)
    VERBOSE=true
    ;;
    --help)
    usage
    ;;
    *)
    # unknown option
    usage
    ;;
esac
done

if [[ -z ${BACKUP_DIR} ]]; then
    echo "ERROR: Please, specify a destination directory for backups using --backup-dir parameter."
    usage
    exit 1
fi

if [[ ! -f ${MYSQL_CONFIG_FILE} ]]; then
    echo "ERROR: Mysql client config file ${MYSQL_CONFIG_FILE} does not exist."
    exit 1
fi

APP_PID=0
MYSQL_CONFIG_FILE=$(realpath ${MYSQL_CONFIG_FILE})
BACKUP_DIR=$(realpath ${BACKUP_DIR})
LOG_DIR=$(realpath ${LOG_DIR})

log "Initializing binlog sync"
log "Backup destination: $BACKUP_DIR"
log "Log destination: $LOG_DIR"

mkdir -p ${LOG_DIR} || exit 1
mkdir -p ${BACKUP_DIR} || exit 1
cd ${BACKUP_DIR} || exit 1

log "Reading mysql client configuration from $MYSQL_CONFIG_FILE"

while :
do
    # check pid and continue
    if [[ "$APP_PID" -gt "0" ]]; then
        # check pid to see if mysqlbinlog is running
        APP_NAME=$(ps -p ${APP_PID} -o cmd= | awk '{ print $1 }')
        if [[ "${APP_NAME}" -eq "mysqlbinlog" ]]; then
            sleep 5
            continue
        fi
    fi

    # Check last backup file to continue from (2> /dev/null suppresses error output)
    LAST_BACKUP_FILE=`ls -1 ${BACKUP_DIR}/${BACKUP_PREFIX}* 2> /dev/null | grep -v ".orig" | tail -n 1`
    log "Last used backup file is $LAST_BACKUP_FILE"

    BINLOG_START_FILE_NAME=""

    if [[ -z ${LAST_BACKUP_FILE} ]]; then
        # If there is no backup yet, find the first binlog file to start copying
        BINLOG_INDEX_FILE=`mysql --defaults-extra-file=${MYSQL_CONFIG_FILE} -Bse "SHOW GLOBAL VARIABLES LIKE 'log_bin_index'" | tail -1 | awk '{ print $2 }'`
        BINLOG_START_FILE=`head -n 1 "$BINLOG_INDEX_FILE"`
        log "Most recent binlog file is ${BINLOG_START_FILE}"

        BINLOG_START_FILE_NAME=`basename "${BINLOG_START_FILE}"`
    else
        # If mysqlbinlog crashes/exits in the middle of execution, we cant know the last position reliably.
        # Thats why starting from the beginning of the same binlog file
        LAST_BACKUP_FILE=$(basename ${LAST_BACKUP_FILE})

        # CAUTION:
        # If the last backup file is too old, the relevant binlog file might not exist anymore
        # In this case, there will be a gap in binlog backups

        # Storing a backup of the latest binlog backup file before exit/crash
        FILE_SIZE=$(stat -c%s ${BACKUP_DIR}/${LAST_BACKUP_FILE})
        if [[ ${FILE_SIZE} -gt 0 ]]; then
            # Timestamp the file to be more verbose
            log "Backing up last binlog file ${LAST_BACKUP_FILE}"
            mv "${BACKUP_DIR}/${LAST_BACKUP_FILE}" "${BACKUP_DIR}/${LAST_BACKUP_FILE}.orig$(date +%s)"
        fi

        # strip backup file prefix to get real binlog name
        LAST_BACKUP_FILE=${LAST_BACKUP_FILE/$BACKUP_PREFIX/}
        BINLOG_START_FILE_NAME=`basename "${LAST_BACKUP_FILE}"`
    fi

    log "Starting live binlog backup from ${BINLOG_START_FILE_NAME}"

    # --compress option also supported in Percona's mysqlbinlog

    mysqlbinlog --defaults-extra-file=${MYSQL_CONFIG_FILE} \
        --raw --read-from-remote-server --stop-never \
        --verify-binlog-checksum \
        --result-file=${BACKUP_PREFIX} \
        ${BINLOG_START_FILE_NAME} >> "${LOG_DIR}/status.log" & APP_PID=$!

    log "mysqlbinlog PID=$APP_PID"

done
