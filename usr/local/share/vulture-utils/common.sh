#!/usr/bin/env sh

COLOR_RESET='\033[0m'
COLOR_RED='\033[0;31m'
COLOR_YELLOW="\033[1;33m"
COLOR_GREEN="\033[0;32m"
TEXT_BLINK='\033[5m'

SNAPSHOT_PREFIX="VLT_"

JAILS_LIST="apache haproxy mongodb portal redis rsyslog"

AVAILABLE_DATASET_TYPES="JAIL DB HOMES TMPVAR"
JAIL_DATASETS="apache apache/var apache/var/db apache/usr portal portal/var portal/var/db portal/usr haproxy haproxy/var haproxy/var/db haproxy/usr mongodb mongodb/var mongodb/usr redis redis/var redis/var/db redis/usr rsyslog rsyslog/var rsyslog/var/db rsyslog/usr"
DB_DATASETS="mongodb/var/db"
HOMES_DATASETS="usr/home"
TMPVAR_DATASETS="apache/var/log portal/var/log haproxy/var/log mongodb/var/log redis/var/log rsyslog/var/log tmp var/audit var/cache var/crash var/log var/tmp"
# 'usr' and 'var' are set to nomount, so they don't hold any data (data is held by the root dataset)
export AVAILABLE_DATASET_TYPES JAIL_DATASETS DB_DATASETS HOMES_DATASETS TMPVAR_DATASETS

# If "NO_COLOR" environment variable is present, or we aren't speaking to a
# tty, disable output colors.
if [ -n "${NO_COLOR}" ] || [ ! -t 1 ]; then
    COLOR_RESET=''
    COLOR_RED=''
    COLOR_YELLOW=''
    TEXT_BLINK=''
fi

info() {
    /usr/bin/printf "${COLOR_GREEN}$*${COLOR_RESET}\n"
}

warn() {
    /usr/bin/printf "${COLOR_YELLOW}$*${COLOR_RESET}\n"
}

error() {
    /usr/bin/printf "${COLOR_RED}$*${COLOR_RESET}\n" 1>&2
}

error_and_exit() {
    /usr/bin/printf "${COLOR_RED}$*${COLOR_RESET}\n" 1>&2
    exit 1
}

error_and_blink() {
    /usr/bin/printf "${COLOR_RED}${TEXT_BLINK}$*${COLOR_RESET}\n" 1>&2
}

######################
## System functions ##
######################
exec_mongo() {
    _command="$1"
    _exec=""

    if ! /usr/sbin/jls | /usr/bin/grep -q mongodb; then
        return 1
    fi

    if /usr/sbin/jexec mongodb /usr/bin/command -v connect >/dev/null; then
        _exec="/usr/sbin/jexec mongodb connect -- "
    else
        _exec="/usr/sbin/jexec mongodb mongo --ssl --sslCAFile /var/db/pki/ca.pem --sslPEMKeyFile /var/db/pki/node.pem $(hostname):9091"
    fi

    if [ -z "${_command}" ]; then
        ${_exec}
    else
        ${_exec} --eval "${_command}"
    fi
    return $?
}

exec_redis() {
    _command="$1"
    _password="$(grep -F 'masterauth' /zroot/redis/usr/local/etc/redis/redis.conf | sed -n 's/masterauth "\(.*\)"/\1/p')"

    if ! /usr/sbin/jls | /usr/bin/grep -q redis; then
        return 1
    fi

    if [ -z "${_password}" ]; then
        /usr/sbin/jexec redis /usr/local/bin/redis-cli ${_command}
    else
        REDISCLI_AUTH="$_password" /usr/sbin/jexec redis /usr/local/bin/redis-cli ${_command}
    fi
    return $?
}

add_to_motd() {
    if [ -f /var/run/motd ]; then
        /usr/bin/printf "$1\n" >> /var/run/motd
    fi
}

reset_motd() {
    /usr/sbin/service motd restart
}

get_jail_list() {
    echo "${JAILS_LIST}"
}

has_upgraded_kernel() {
    if [ "$(/usr/bin/uname -U)" -eq "$(/usr/bin/uname -K)" ]; then
        return 0
    else
        /usr/bin/sed -i '' '/Upgrade:/d' /var/run/motd
        error_and_blink "Upgrade: the system has a pending kernel/userland upgrade, please restart your machine to apply!" | /usr/bin/tee -a /var/run/motd
        return 1
    fi
}

get_root_zpool_name() {
    /sbin/mount -l | /usr/bin/grep "on / " | /usr/bin/cut -d / -f 1
}

zfs_dataset_exists() {
    _dataset="$1"
    _zpool="$(get_root_zpool_name)"

    if [ -z "${_dataset}" ]; then
        return 1
    fi

    # Migrated datasets are tied to current BE
    if /sbin/zfs list -H -oname | grep -q "^${_zpool}/${_dataset}\$\|^${_zpool}/ROOT/$(get_current_BE)/${_dataset}\$"; then
        return 0
    else
        return 1
    fi
}

###################
## Miscellaneous ##
###################
sublist() {
    _object_list="$1"
    _index_start="${2:-1}"
    _index_stop="${3:-$(/bin/echo "$_object_list" | /usr/bin/wc -w | /usr/bin/xargs)}"
    _delimiter="${4:- }"

    if [ -n "${_index_start}" ] && [ "${_index_start}" -gt "${_index_stop}" ]; then
        return 0
    fi

    /bin/echo "$_object_list" | /usr/bin/cut -d "${_delimiter}" -f "${_index_start}-${_index_stop}"
    return $((_index_stop - _index_start + 1))
}

contains_word() {
    _list="$1"
    _word_in_list="$2"

    if echo "${_list}" | grep -qw "${_word_in_list}"; then
        return 0
    else
        return 1
    fi
}

################################
## Boot Environment functions ##
################################
get_BEs() {
    # Order BEs (ordered, most recent first)
    /sbin/bectl list -H -Ccreation
}

get_vlt_BEs() {
    get_BEs | /usr/bin/grep "${SNAPSHOT_PREFIX}"
}

get_pending_BE() {
    # Order BEs (ordered, most recent first)
    get_vlt_BEs |\
    while read -r _name _status _rest; do
        # Get only the BE activated temporarily, or for next Boots
        # order is important, as it defines what BE will boot next: 'T' before 'R'
        if [ "${_status}" = "T" ] || [ "${_status}" = "R" ] || [ "${_status}" = "RT" ]; then
            /usr/bin/printf "%s" "${_name}"
            return 0
        fi
    done
    return 1
}

get_current_BE() {
    # DON'T use get_vlt_BEs: all BEs should be listed here
    get_BEs |\
    while read -r _name _status _rest; do
        # Get only the BE activated now
        if /usr/bin/printf "${_status}" | /usr/bin/grep -q "N"; then
            /usr/bin/printf "%s" "${_name}"
            return 0
        fi
    done
    return 1
}

list_inactive_BEs() {
    get_vlt_BEs |\
    while read -r _name _status _rest; do
        # filter out the current BE (tagged with an N in status)
        if /usr/bin/printf "${_status}" | /usr/bin/grep -qv "N"; then
            /usr/bin/printf "%s " "${_name}"
        fi
    done
}

list_unused_BEs() {
    get_vlt_BEs |\
    while read -r _name _status _rest; do
        # filter out any BE that could be N, R, T or a combination of those (man bectl)
        if [ "${_status}" = "-" ]; then
            /usr/bin/printf "%s " "${_name}"
        fi
    done
}

has_pending_BE() {
    _temp_be_search="$(/sbin/bectl list -H | cut -f 2 | grep -F 'T')"
    _stable_be_search="$(/sbin/bectl list -H | cut -f 2 | grep -E '(RN|NR)')"

    if [ -z "${_temp_be_search}" ] && [ -n "${_stable_be_search}" ]; then
        return 0
    else
        sed -i '' '/Upgrade:/d' /var/run/motd
        error_and_blink "Upgrade: the system has a pending new Boot Environment, please restart your machine to apply!" | tee -a /var/run/motd
        return 1
    fi
}

clean_old_BEs() {
    _number_to_keep="$1"
    _deletable_BEs="$(list_unused_BEs)"

    if [ "${_number_to_keep}" -ne "${_number_to_keep}" ]; then
        return 1
    fi

    _to_delete="$(sublist "${_deletable_BEs}" $((_number_to_keep+1)))"
    for _be in $_to_delete; do
        /bin/echo "Destroying old BE: '${_be}'"
        /sbin/bectl destroy -o "$_be"
    done
}

# Delete a specific boot environment
delete_BE() {
    _be_name="$1"

    if [ -z "${_be_name}" ]; then
        error "[!] No Boot Environment name provided"
        return 1
    fi

    # Check if BE exists in the list of vulture BEs
    _existing_bes="$(get_vlt_BEs | cut -f 1)"
    if ! contains_word "${_existing_bes}" "${_be_name}"; then
        error "[!] Boot Environment '${_be_name}' not found"
        return 1
    fi

    # Check if BE is currently active (status contains 'N')
    _be_status="$(get_BEs | grep "^${_be_name}	" | cut -f 2)"
    if printf "%s" "${_be_status}" | grep -q "N"; then
        error "[!] Cannot delete active Boot Environment '${_be_name}'"
        return 1
    fi

    echo "Destroying Boot Environment: '${_be_name}'"
    /sbin/bectl destroy -o "${_be_name}"
    return $?
}

# Delete a specific snapshot from datasets
delete_snapshot_from_datasets() {
    _datasets="$1" # space-separated list of datasets
    _snap_to_delete="$2" # snapshot name to delete
    _zpool="$(get_root_zpool_name)"
    _deleted_count=0

    if [ -z "${_datasets}" ] || [ -z "${_snap_to_delete}" ]; then
        error "[!] Missing arguments for snapshot deletion"
        return 1
    fi

    for _dataset in ${_datasets}; do
        if zfs_dataset_exists "${_dataset}"; then
            _existing_snaps="$(list_snapshots "${_dataset}")"
            if contains_word "${_existing_snaps}" "${_snap_to_delete}"; then
                echo "Deleting snapshot '${_zpool}/${_dataset}@${_snap_to_delete}'"
                if /sbin/zfs destroy "${_zpool}/${_dataset}@${_snap_to_delete}" || \
                    /sbin/zfs destroy "${_zpool}/ROOT/$(get_current_BE)/${_dataset}@${_snap_to_delete}"; then
                    _deleted_count=$((_deleted_count + 1))
                else
                    error "[!] Failed to delete snapshot '${_zpool}/${_dataset}@${_snap_to_delete}'"
                fi
            fi
        fi
    done

    if [ "${_deleted_count}" -eq 0 ]; then
        warn "[!] No snapshot '${_snap_to_delete}' found in specified datasets"
        return 1
    fi

    return 0
}


############################
## Snapshotting functions ##
############################
snapshot_datasets() {
    _datasets="$1"
    _snapshot_name="$2"
    _zpool="$(get_root_zpool_name)"

    if [ -z "${_datasets}" ] || [ -z "${_snapshot_name}" ]; then
        return 1
    fi

    for dataset in ${_datasets}; do
        if zfs_dataset_exists "${dataset}"; then
            /sbin/zfs snap "${_zpool}/${dataset}@${_snapshot_name}" || \
                /sbin/zfs snap "${_zpool}/ROOT/$(get_current_BE)/${dataset}@${_snapshot_name}"
        fi
    done
}

list_snapshots() {
    _dataset="$1"
    _zpool="$(get_root_zpool_name)"

    if [ -z "${_dataset}" ]; then
        return 1
    fi

    if zfs_dataset_exists "${_dataset}"; then
        # List snapshot names only, ordering by descending order (most recent first)
        (/sbin/zfs list -H -tsnap -oname -Screation "${_zpool}/${_dataset}" 2>/dev/null ||\
            /sbin/zfs list -H -tsnap -oname -Screation "${_zpool}/ROOT/$(get_current_BE)/${_dataset}") |\
            # Get snapshot name part (remove dataset part)
            /usr/bin/cut -d '@' -f 2 |\
            # filter out snapshot not created by scripts
            /usr/bin/grep -E "^${SNAPSHOT_PREFIX}.*" |\
            # remove leading/trailing whitespaces and return a single string with elements separated by a space
            /usr/bin/xargs
    fi
}

clean_previous_snapshots() {
    _datasets="$1"
    _number_to_keep="$2"
    _zpool="$(get_root_zpool_name)"

    # arguments are mandatory
    if [ -z "${_datasets}" ] || [ -z "${_number_to_keep}" ]; then
        return 1
    fi
    # _number_to_keep should be a number
    if [ "${_number_to_keep}" -ne "${_number_to_keep}" ]; then
        return 1
    fi

    for _dataset in ${_datasets}; do
        if zfs_dataset_exists "${_dataset}"; then
            # most recent are first in list
            _ordered_snapshots="$(list_snapshots "${_dataset}")"

            # List index begins at 1, so remove from the next element to the last
            _snaps_to_remove="$(sublist "${_ordered_snapshots}" "$((_number_to_keep+1))")"
            for _snap in $_snaps_to_remove; do
                /bin/echo "removing snapshot '${_zpool}/${_dataset}@${_snap}'"
                /sbin/zfs destroy "${_zpool}/${_dataset}@${_snap}" ||\
                    /sbin/zfs destroy "${_zpool}/ROOT/$(get_current_BE)/${_dataset}@${_snap}"
            done
        fi
    done
}


###########################
## Rollbacking functions ##
###########################
tag_snapshots_for_rollback() {
    _datasets="$1"
    _snapshot="$2"
    _zpool="$(get_root_zpool_name)"

    # arguments are mandatory
    if [ -z "${_datasets}" ] || [ -z "${_snapshot}" ]; then
        return 1
    fi
    for _dataset in ${_datasets}; do
        if zfs_dataset_exists "${_dataset}"; then
            echo "will rollback to ${_zpool}/${_dataset}@${_snapshot}"
            /sbin/zfs set snapshot:restore=YES "${_zpool}/${_dataset}@${_snapshot}" ||\
                /sbin/zfs set snapshot:restore=YES "${_zpool}/ROOT/$(get_current_BE)/${_dataset}@${_snapshot}"
        fi
    done
}

list_pending_rollbacks() {
    _dataset="$1"
    _zpool="$(get_root_zpool_name)"
    _snap_name=""

    # argument is mandatory
    if [ -z "${_dataset}" ]; then
        return 1
    fi

    if zfs_dataset_exists "${_dataset}"; then
        (/sbin/zfs list -H -tsnap -o name,snapshot:restore "${_zpool}/${_dataset}" 2>/dev/null ||\
            /sbin/zfs list -H -tsnap -o name,snapshot:restore "${_zpool}/ROOT/$(get_current_BE)/${_dataset}" 2>/dev/null) |\
        while read -r _name _status; do
            if [ "${_status}" = "YES" ]; then
                _snap_name=$(echo "${_name}" | cut -d @ -f 2)
                /usr/bin/printf "%s " "${_snap_name}"
            fi
        done
    fi
}

clean_rollback_state_on_datasets() {
    _datasets="$1"
    _zpool="$(get_root_zpool_name)"

    # argument is mandatory
    if [ -z "${_datasets}" ]; then
        return 1
    fi

    for _dataset in ${_datasets}; do
        if zfs_dataset_exists "${_dataset}"; then
            _snapshot_list="$(list_pending_rollbacks "${_dataset}")"
            for _snapshot in ${_snapshot_list}; do
                echo "Resetting rollback state for ${_dataset}"
                /sbin/zfs inherit snapshot:restore "${_zpool}/${_dataset}@${_snapshot}" ||\
                    /sbin/zfs inherit snapshot:restore "${_zpool}/ROOT/$(get_current_BE)/${_dataset}@${_snapshot}"
            done
        fi
    done
}
