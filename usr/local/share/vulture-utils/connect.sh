#!/usr/bin/env sh

. /usr/local/share/vulture-utils/common.sh

#############
# variables #
#############
VALID_JAILS="mongodb redis"

#############
# functions #
#############
usage() {
    echo "USAGE connect [jail name]"
    echo "This script is a wrapper to connect easily to mongodb or redis"
    echo ""
    echo "OPTIONS:"
    echo "	-h	Display this help message"
    exit 1
}

####################
# parse parameters #
####################
while getopts 'h' opt; do
    case "${opt}" in
        h|*)  usage;
            ;;
    esac
done
shift $((OPTIND-1))

jail="$1"
shift
_params="$*"

case "$jail" in
    mongodb)
        exec_mongo "$_params"
        ;;
    redis)
        exec_redis "$_params"
        ;;
    *)
        echo "Error: '$jail' is not a valid jail."
        echo "Available jails: $VALID_JAILS"
        exit 1
        ;;
esac
