#!/bin/bash

########### syncbinlog.sh #############
# Copyright 2019 Arda Beyazoglu
# MIT License
#
# A bash script that uses mysqlbinlog
# utility to syncronize binlog files
#######################################

# Write usage
usage() {
    echo -e "Usage: $(basename $0) [options]"
    echo -e "\tStarts live binlog sync using mysqlbinlog utility\n"
    echo -e "   --backup-dir=        Backup destination directory (required)"
    echo -e "   --log-dir=           Log directory (defaults to '/var/log/syncbinlog')"
    echo -e "   --prefix=            Backup file prefix (defaults to 'backup-')"
    echo -e "   --mysql-conf=        Mysql defaults file for client auth (defaults to './.my.cnf')"
    echo -e "   --compress           Compress backuped binlog files"
    echo -e "   --compress-app=      Compression app (defaults to 'pigz'). Compression parameters can be given as well (e.g. pigz -p6 for 6 threaded compression)"
    echo -e "   --rotate=X           Rotate backup files for X days (defaults to 30)"
    echo -e "   --verbose=           Write logs to stdout as well"
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

# Parse configuration parameters
parse_config() {
    for arg in ${ARGS}
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
            --compress)
            COMPRESS=true
            ;;
            --compress-app=*)
            COMPRESS_APP="${arg#*=}"
            ;;
            --rotate=*)
            ROTATE_DAYS="${arg#*=}"
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
}

# Compress backup files that are currently open
compress_files() {
    # find last modified binlog backup file (except the *.original ones)
    LAST_MODIFIED_BINLOG_FILE=$(find ${BACKUP_DIR} -type f -name "${BACKUP_PREFIX}${BINLOG_BASENAME}*" -printf "%T@ %p\n" | sort -n | tail -1 | awk '{print $2}' | grep -P ".+\.[0-9]+$")
    LAST_MODIFIED_BINLOG_FILE=$(basename ${LAST_MODIFIED_BINLOG_FILE})

    # find all binlog backup files sorted by modification date
    SORTED_BINLOG_FILES=$(find ${BACKUP_DIR} -type f -name "${BACKUP_PREFIX}${BINLOG_BASENAME}*" -printf "%T@ %p\n" | sort -n | awk '{print $2}' | grep -P ".+\.[0-9]+(|\.original)$")

    for filename in ${SORTED_BINLOG_FILES}
    do
        # check if file exists
        [[ -f "${filename}" ]] || break

        # break on last modified backup file, because its not completely written yet
        [[ `basename ${filename}` == "${LAST_MODIFIED_BINLOG_FILE}" ]] && break

        log "Compressing ${filename}"
        ${COMPRESS_APP} --force ${filename} > "${LOG_DIR}/status.log"
        log "Compressed ${filename}"
    done
}

# Rotate older backups
rotate_files() {
    # find binlog backup files older than rotation period
    ROTATED_FILES=$(find ${BACKUP_DIR} -type f -name "${BACKUP_PREFIX}${BINLOG_BASENAME}*" -mtime +${ROTATE_DAYS} | grep -P ".+\.[0-9]+(|\.original)$")
    for filename in ${ROTATED_FILES}
    do
        log "Rotation: deleting ${filename}"
        rm ${filename}
    done
}

# Exit safely on signal
die() {
    log "Exit signal caught!"
    log "Stopping child processes before exit"
    trap - SIGINT SIGTERM # clear the listener
    kill -- -$$ # Sends SIGTERM to child/sub processes
    if [[ ! -z ${APP_PID} ]]; then
        log "Killing mysqlbinlog process"
        kill ${APP_PID}
    fi
}

# listen to the process signals
trap die SIGINT SIGTERM

# Default configuration parameters
MYSQL_CONFIG_FILE=./.my.cnf
BACKUP_DIR=""
LOG_DIR=/var/log/syncbinlog
BACKUP_PREFIX="backup-"
COMPRESS=false
COMPRESS_APP="pigz -p$(($(nproc) - 1))"
ROTATE_DAYS=30
VERBOSE=false

ARGS="$@"
parse_config

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

mkdir -p ${LOG_DIR} || exit 1
mkdir -p ${BACKUP_DIR} || exit 1
cd ${BACKUP_DIR} || exit 1

log "Initializing binlog sync"
log "Backup destination: $BACKUP_DIR"
log "Log destination: $LOG_DIR"
log "Reading mysql client configuration from $MYSQL_CONFIG_FILE"

BINLOG_BASENAME=$(mysql --defaults-extra-file=${MYSQL_CONFIG_FILE} -Bse "SHOW GLOBAL VARIABLES LIKE 'log_bin_basename'")
if [[ $? -eq "1" ]]; then
    log "Please, check your mysql credentials" "ERROR"
    exit 1
fi

BINLOG_BASENAME=$(basename `echo ${BINLOG_BASENAME} | tail -1 | awk '{ print $2 }'`)
log "Binlog file basename is $BINLOG_BASENAME"

BINLOG_INDEX_FILE=`mysql --defaults-extra-file=${MYSQL_CONFIG_FILE} -Bse "SHOW GLOBAL VARIABLES LIKE 'log_bin_index'" | tail -1 | awk '{ print $2 }'`
log "Binlog index file is $BINLOG_BASENAME"

BINLOG_LAST_FILE=`tail -1 "$BINLOG_INDEX_FILE"`
log "Most recent binlog file is $BINLOG_BASENAME"

while :
do
    RUNNING=false

    # check pid to see if mysqlbinlog is running
    if [[ "$APP_PID" -gt "0" ]]; then
        # check process name to ensure it is mysqlbinlog pid
        APP_NAME=$(ps -p ${APP_PID} -o cmd= | awk '{ print $1 }')
        if [[ ${APP_NAME} == "mysqlbinlog" ]]; then
            RUNNING=true
        fi
    fi

    if [[ ${RUNNING} ]]; then
        # check older backups to compress
        ${COMPRESS} && compress_files

        # check file timestamps to apply rotation
        rotate_files

        # sleep and continue
        sleep 10
        continue
    fi

    # Check last backup file to continue from (2> /dev/null suppresses error output)
    LAST_BACKUP_FILE=`ls -1 ${BACKUP_DIR}/${BACKUP_PREFIX}* 2> /dev/null | grep -v ".original" | tail -n 1`

    BINLOG_SYNC_FILE_NAME=""

    if [[ -z ${LAST_BACKUP_FILE} ]]; then
        log "No backup file found, starting from oldest binary log in the server"

        # If there is no backup yet, find the first binlog file to start copying
        BINLOG_START_FILE=`head -n 1 "$BINLOG_INDEX_FILE"`
        log "The oldest binlog file is ${BINLOG_START_FILE}"

        BINLOG_SYNC_FILE_NAME=`basename "${BINLOG_START_FILE}"`
    else
        # If mysqlbinlog crashes/exits in the middle of execution, we cant know the last position reliably.
        # Thats why restart syncing from the beginning of the same binlog file
        LAST_BACKUP_FILE=$(basename ${LAST_BACKUP_FILE})
        log "Last used backup file is $LAST_BACKUP_FILE"

        # CAUTION:
        # If the last backup file is too old, the relevant binlog file might not exist anymore
        # In this case, there will be a gap in binlog backups

        # Storing a backup of the latest binlog backup file before exit/crash
        FILE_SIZE=$(stat -c%s ${BACKUP_DIR}/${LAST_BACKUP_FILE})
        if [[ ${FILE_SIZE} -gt 0 ]]; then
            log "Backing up last binlog file ${LAST_BACKUP_FILE}"
            mv "${BACKUP_DIR}/${LAST_BACKUP_FILE}" "${BACKUP_DIR}/${LAST_BACKUP_FILE}.original"
        fi

        # strip backup file prefix to get real binlog name
        LAST_BACKUP_FILE=${LAST_BACKUP_FILE/$BACKUP_PREFIX/}
        BINLOG_SYNC_FILE_NAME=`basename "${LAST_BACKUP_FILE}"`
    fi

    log "Starting live binlog backup from ${BINLOG_SYNC_FILE_NAME}"

    mysqlbinlog --defaults-extra-file=${MYSQL_CONFIG_FILE} \
        --raw --read-from-remote-server --stop-never \
        --verify-binlog-checksum \
        --result-file=${BACKUP_PREFIX} \
        ${BINLOG_SYNC_FILE_NAME} >> "${LOG_DIR}/status.log" & APP_PID=$!

    log "mysqlbinlog PID=$APP_PID"

done
