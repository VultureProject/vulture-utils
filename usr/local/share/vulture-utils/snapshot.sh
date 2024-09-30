#!/usr/bin/env sh

. /usr/local/share/vulture-utils/common.sh

#############
# variables #
#############
snap_name="${SNAPSHOT_PREFIX}SNAP_$(date +%Y-%m-%dT%H:%M:%S)"
list_snaps=0
keep_previous_snap=-1
_mongo_locked=0
_snapshot_datasets_list=""

#############
# functions #
#############
usage() {
    echo "USAGE snapshot OPTIONS"
    echo "OPTIONS:"
    echo "	-A	Snapshot all underlying datasets"
    echo "	-S	Snapshot the system dataset(s)"
    echo "	-J	Snapshot the jail(s) dataset(s)"
    echo "	-H	Snapshot the home dataset(s)"
    echo "	-D	Snapshot the databases dataset(s)"
    echo "	-T	Snapshot the tmp/var dataset(s)"
    echo "	-l	Only list datasets"
    echo "	-k <num>	Keep <num> snapshots for the targeted datasets"
    exit 1
}


if [ "$(/usr/bin/id -u)" != "0" ]; then
    error "[!] This script must be run as root"
    exit 1
fi

while getopts 'hASJDHTlk:' opt; do
    case "${opt}" in
        A)  _snapshot_datasets_list="SYSTEM JAIL DB HOMES TMPVAR";
            ;;
        S)  _snapshot_datasets_list="${_snapshot_datasets_list} SYSTEM";
            ;;
        J)  _snapshot_datasets_list="${_snapshot_datasets_list} JAIL";
            ;;
        D)  _snapshot_datasets_list="${_snapshot_datasets_list} DB";
            ;;
        H)  _snapshot_datasets_list="${_snapshot_datasets_list} HOMES";
            ;;
        T)  _snapshot_datasets_list="${_snapshot_datasets_list} TMPVAR";
            ;;
        l)  list_snaps=1;
            ;;
        k)  keep_previous_snap=${OPTARG};
            ;;
        h|*)  usage;
            ;;
    esac
done
shift $((OPTIND-1))

trap finalize SIGINT

finalize(){
    if [ "$_mongo_locked" -gt 0 ]; then
        exec_mongo "db.fsyncUnlock()" > /dev/null
        _mongo_locked=0
    fi
}

for _type in ${AVAILABLE_DATASET_TYPES}; do
    _type_datasets="$(eval 'echo "$'"$_type"'_DATASETS"')"
    _snapshot_list="$(list_snapshots "$(echo "${_type_datasets}" | cut -d ' ' -f1)")"

    # List snapshots
    if [ "${list_snaps}" -gt 0 ]; then
        printf "%s:\t" "${_type}"
        for _snap in $_snapshot_list; do
            printf "%s\t" "$_snap"
        done
        printf "\n"
    # snapshotting datasets
    else
        # Ignore datasets not explicitely selected
        if ! contains "${_snapshot_datasets_list}" "${_type}"; then
            continue
        fi
        if [ "${_type}" = "DB" ] && [ "${_mongo_locked}" -eq 0 ]; then
            exec_mongo "db.fsyncLock()" > /dev/null
            _mongo_locked=1
        fi
        echo "making new snapshot for ${_type} datasets"
        snapshot_datasets "$_type_datasets" "$snap_name"
        if [ "$keep_previous_snap" -ge 0 ]; then
            echo "keeping only $keep_previous_snap version(s) for '${_type}' dataset(s)"
            clean_previous_snapshots "$_type_datasets" "$keep_previous_snap"
        fi
    fi
done

finalize
