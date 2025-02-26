#!/usr/bin/env sh
# shellcheck disable=SC1091

. /usr/local/share/vulture-utils/common.sh

#############
# variables #
#############
clean_rollback_triggers=0
list_rollbacks=0
rollback_system=0
rollback_to=""
_need_restart=0
_rollback_datasets_list=""

# 'usr' and 'var' are set to nomount, so they don't hold any data (data is held by the root dataset)

#############
# functions #
#############
usage() {
    echo "USAGE restore OPTIONS"
    echo "This stript triggers rollbacks on all or specific datasets, machine should then be restarted to apply the rollbacks"
    echo ""
    echo "OPTIONS:"
    echo "	-A	act on all underlying datasets"
    echo "	-S	act on the system dataset(s)"
    echo "	-J	act on the jail(s) dataset(s)"
    echo "	-H	act on the home dataset(s)"
    echo "	-D	act on the databases dataset(s)"
    echo "	-T	act on the tmp/var dataset(s)"
    echo "	-c	Reset selected dataset(s) rollback triggers"
    echo "	-l	List all datasets and their planned rollbacks"
    echo "	-r	<timestamp>	Select a custom timestamp to rollback to (snapshot should exist with that timestamp, you can get valid timestamps for every dataset with the 'snapshot.sh -l' command)"
    exit 1
}


if [ "$(/usr/bin/id -u)" != "0" ]; then
    error "[!] This script must be run as root"
    exit 1
fi

while getopts 'hASJHDTclr:' opt; do
    case "${opt}" in
        A)  _rollback_datasets_list="SYSTEM JAIL DB HOMES TMPVAR";
            rollback_system=1;
            ;;
        S)  # the system is snapshotted using bectl, and not regular snapshots
            rollback_system=1;
            ;;
        J)  _rollback_datasets_list="${_rollback_datasets_list} JAIL"
            ;;
        D)  _rollback_datasets_list="${_rollback_datasets_list} DB"
            ;;
        H)  _rollback_datasets_list="${_rollback_datasets_list} HOMES"
            ;;
        T)  _rollback_datasets_list="${_rollback_datasets_list} TMPVAR"
            ;;
        c)  clean_rollback_triggers=1;
            ;;
        l)  list_rollbacks=1;
            ;;
        r)  rollback_to=${OPTARG};
            ;;
        h|*)  usage;
            ;;
    esac
done
shift $((OPTIND-1))

trap finalize_early INT

finalize() {
    # set default in case err_code is not specified
    err_code=$1
    err_message=$2
    # does not work with '${1:=0}' if $1 is not set...
    err_code=${err_code:=0}

    if [ -n "$err_message" ]; then
        echo ""
        error "[!] ${err_message}"
        echo ""
    fi

    if [ "${_need_restart}" -gt 0 ];then
        info "Dataset have planned rollbacks, restart machine to apply them!"
    fi

    exit "$err_code"
}

finalize_early() {
    # shellcheck disable=SC2317
    finalize 1 "Stopped"
}

# SYSTEM dataset (using bectl)
if [ "${list_rollbacks}" -gt 0 ]; then
    printf "SYSTEM:\t"
    get_pending_BE
    printf "\n"
elif [ "${rollback_system}" -gt 0 ]; then
    /sbin/bectl activate -T
    if [ "$clean_rollback_triggers" -gt 0 ]; then
        _current_BE="$(get_current_BE)"
        if [ -n "${_current_BE}" ]; then
            /sbin/bectl activate "$(get_current_BE)"
        else
            error_and_exit "[!] Could not get current Boot Environment, cannot reset BE state!"
        fi
    else
        BE_to_rollback="$(list_inactive_BEs | cut -d ' ' -f1)"
        if [ -n "${rollback_to}" ]; then
            BE_to_rollback="$(list_inactive_BEs | grep -o "${rollback_to}")"
        fi
        if [ -z "${BE_to_rollback}" ]; then
            error_and_exit "[!] Snapshot not found, cannot rollback SYSTEM dataset"
        else
            echo "rollbacking SYSTEM"
            /sbin/bectl activate "${BE_to_rollback}"
            _need_restart=1
        fi
    fi
fi

# OTHER datatypes (using regular snapshots)
for _type in ${AVAILABLE_DATASET_TYPES}; do
    _type_datasets="$(eval 'echo "$'"$_type"'_DATASETS"')"
    _rollback_list="$(list_pending_rollbacks "$(echo "${_type_datasets}" | cut -d ' ' -f1)")"

    if [ "${list_rollbacks}" -gt 0 ]; then
        printf "%s:\t" "${_type}"
        for _rollback in $_rollback_list; do
            printf "%s\t" "$_rollback"
        done
        printf "\n"
        continue
    fi

    # Ignore datasets not explicitely selected from here
    if ! contains_word "${_rollback_datasets_list}" "${_type}"; then
        continue
    fi

    if [ $clean_rollback_triggers -gt 0 ]; then
        clean_rollback_state_on_datasets "${_type_datasets}"
    else
        echo "rollbacking ${_type}"
        clean_rollback_state_on_datasets "${_type_datasets}"
        _snapshot_list="$(list_snapshots "$(echo "${_type_datasets}" | cut -d ' ' -f1)")"
        # Get latest snapshot by default
        _snapshot_to_rollback="$(sublist "${_snapshot_list}" "1" "1")"
        if [ -n "${rollback_to}" ]; then
            _snapshot_to_rollback="$(echo "${_snapshot_list}" | grep -o "${rollback_to}")"
        fi
        if [ -z "${_snapshot_to_rollback}" ];then
            error_and_exit "[!] Snapshot not found, cannot rollback ${_type} dataset(s)"
        else
            _need_restart=1
            tag_snapshots_for_rollback "${_type_datasets}" "${_snapshot_to_rollback}"
        fi
    fi
done

finalize
