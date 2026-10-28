#!/usr/bin/env sh
# shellcheck disable=SC1091

. /usr/local/share/vulture-utils/common.sh

COLOR_OFF='\033[0m'
COLOR_RED='\033[0;31m'

temp_dir="/var/tmp/update"
major_version=15
target_mongodb_version="mongodb70"
pkg_url="http://pkg.vultureproject.org/"
update_url="http://hbsd.vultureproject.org/"
vulture_conf="Vulture.conf"
pkg_ca="pkg.vultureproject.org"
vulture_update_ca="ca.vultureproject.org"
new_be="${SNAPSHOT_PREFIX}HBSD${major_version}"

download_only=0
auto_reboot=0
_run_ok=0

download_system_update() {
    _mnt_temp_dir="$1"

    if [ ! -f ${temp_dir}/update.tar ]; then
        /usr/bin/sed -i ".bak" -E "s/[0-9]+-stable/${major_version}-stable/g" "$_mnt_temp_dir/etc/hbsd-update.conf"
        update_repositories "$_mnt_temp_dir"

        info "[+] Downloading system update..."
        /usr/sbin/hbsd-update -d -t "$temp_dir" -T -f -c "$_mnt_temp_dir/etc/hbsd-update.conf" || finalize 1 "System update download failed."
        info "[-] Done."
    else
        info "[+] OS upgrade files found, nothing to download."
    fi
}

update_system() {
    _mnt_temp_dir="$1"
    _jail="$2"
    _options=""

    if [ -n "$_jail" ] ; then
        _options="-n"
        if [ -d "$_mnt_temp_dir/.jail_system" ]; then
            _path="$_mnt_temp_dir/.jail_system"
        else
            _path="$_mnt_temp_dir/zroot/$_jail"
        fi
    else
        _path="$_mnt_temp_dir"
    fi

    /usr/bin/sed -i ".bak" -E "s/[0-9]+-stable/${major_version}-stable/g" "$_path/etc/hbsd-update.conf"
    update_repositories "$_path"

    info "[+] Updating base system..."
    # shellcheck disable=SC2086
    /usr/bin/yes "mf" | /usr/sbin/hbsd-update -t "$temp_dir" -T -D -r $_path -c $_path/etc/hbsd-update.conf $_options || finalize 1 "System update failed."
    info "[-] Done with update."
}

download_packages() {
    _mnt_temp_dir="$1"

    pkg_env="/usr/bin/env IGNORE_OSVERSION=yes ASSUME_ALWAYS_YES=yes"
    pkg_args="-c $_mnt_temp_dir -o ABI=FreeBSD:${major_version}:amd64"

    info "[+] Updating root pkg repository catalogue..."
    # shellcheck disable=SC2086
    $pkg_env /usr/sbin/pkg $pkg_args update -f || finalize 1 "Could not update list of packages."
    info "[-] Done."

    info "[+] Clear pkg cache before fetching..."
    # shellcheck disable=SC2086
    $pkg_env /usr/sbin/pkg $pkg_args clean -a || finalize 1 "Could not clear pkg cache."
    info "[-] Done."

    info "[+] Fetching host's packages..."
    # shellcheck disable=SC2086
    $pkg_env /usr/sbin/pkg $pkg_args unlock vulture-base vulture-gui vulture-haproxy vulture-mongodb vulture-redis vulture-rsyslog
    # shellcheck disable=SC2086
    $pkg_env /usr/sbin/pkg $pkg_args fetch -u || finalize 1 "Failed to download packages."
    # shellcheck disable=SC2086
    $pkg_env /usr/sbin/pkg $pkg_args lock vulture-base vulture-gui vulture-haproxy vulture-mongodb vulture-redis vulture-rsyslog
    info "[-] Done."

    for jail in $JAILS_LIST; do
        pkg_args="-c $_mnt_temp_dir/zroot/$jail -o ABI=FreeBSD:${major_version}:amd64"

        # shellcheck disable=SC2086
        $pkg_env /usr/sbin/pkg $pkg_args clean -a || finalize 1 "Could not clear pkg cache for jail $jail."
        info "[+] Fetching $jail's packages..."
        # shellcheck disable=SC2086
        $pkg_env /usr/sbin/pkg $pkg_args fetch -u || finalize 1 "Failed to download packages for jail $jail."
        info "[-] Done."
    done
}

update_repositories() {
    prefix_dir="$1"
    _log_header=""
    _os_release="$(/usr/sbin/sysrc -f "$prefix_dir/etc/hbsd-update.conf" -n branch)" || finalize 1 "Could not get current OS release, please upgrade hbsd-update.conf file."
    _os_branch_version="$(/usr/sbin/sysrc -f "$prefix_dir/etc/hbsd-update.conf" -n os_version)" || finalize 1 "Could not get current OS branch version, please upgrade hbsd-update.conf file."
    _vulture_update_conf="hbsd-update-${_os_release}-${_os_branch_version}.conf"

    if [ -n "$prefix_dir" ]; then
        _log_header="[${prefix_dir}]"
    fi
    if [ -d "${prefix_dir}/usr/local/etc/pkg/repos/" ]; then
        /usr/bin/printf "\033[38;5;172m[!]${_log_header} Disabling custom repos in ${prefix_dir}/usr/local/etc/pkg\033[0m\n"
        /usr/bin/sed -i '' 's/enabled\(.*\)yes/enabled\1no/' "${prefix_dir}"/usr/local/etc/pkg/repos/*.conf
        if [ -e "${prefix_dir}/usr/local/etc/pkg/repos/vulture.conf" ]; then
            /bin/rm -f "${prefix_dir}/usr/local/etc/pkg/repos/vulture.conf"
        fi
        /bin/echo "[-]${_log_header} Done"
    fi

    /usr/bin/printf "[*]${_log_header} Backing up default configurations:"
    for conf in "${prefix_dir}"/etc/hbsd-update*.conf ; do
        conf=$(basename "${conf}")
        if [ ! -f "${prefix_dir}/var/backups/${conf}.bak" ]; then
            /usr/bin/printf "."
            /bin/mv "${prefix_dir}/etc/$conf" "${prefix_dir}/var/backups/${conf}.bak"
        fi
    done
    /bin/echo "."
    /bin/echo "[*]${_log_header} Backups kept at ${prefix_dir}/var/backups/"
    /bin/echo "[-]${_log_header} Done"

    /usr/bin/printf "[+]${_log_header} Updating repositories "
    if [ -n "$prefix_dir" ]; then
        /usr/bin/printf "at $prefix_dir"
    else
        /usr/bin/printf "on system"
    fi

    if [ ! -f ${temp_dir}/${vulture_conf} ]; then
        /usr/bin/fetch -q -o "${temp_dir}" ${pkg_url}${vulture_conf} || finalize 1 "[/] Failed to download $vulture_conf"
        /usr/bin/printf "."
    fi

    /usr/bin/sed "s/current/${_os_release}/" "${temp_dir}/${vulture_conf}" > "${prefix_dir}/etc/pkg/${vulture_conf}"
    /usr/bin/printf "."

    if [ ! -f ${temp_dir}/${pkg_ca} ]; then
        /usr/bin/fetch -q -o "${temp_dir}" ${pkg_url}${pkg_ca} || finalize 1 "[/] Failed to download $pkg_ca"
        /usr/bin/printf "."
    fi

    /bin/mkdir -p "${prefix_dir}/usr/share/keys/pkg/trusted" && /bin/cp -f "${temp_dir}/${pkg_ca}" "${prefix_dir}/usr/share/keys/pkg/trusted/${pkg_ca}"
    /usr/bin/printf "."

    if [ ! -f "${temp_dir}/${_vulture_update_conf}" ]; then
        /usr/bin/fetch -q -o "${temp_dir}" "${update_url}${_vulture_update_conf}" || finalize 1 "[/] Failed to download $_vulture_update_conf"
        /usr/bin/printf "."
    fi

    /bin/mkdir -p "${prefix_dir}/etc" && /bin/cp -f "${temp_dir}/${_vulture_update_conf}" "${prefix_dir}/etc/hbsd-update.conf"
    /usr/bin/printf "."

    if [ ! -f ${temp_dir}/${vulture_update_ca} ]; then
        /usr/bin/fetch -q -o "${temp_dir}" ${update_url}${vulture_update_ca} || finalize 1 "[/] Failed to download $vulture_update_ca"
        /usr/bin/printf "."
    fi

    /bin/mkdir -p "${prefix_dir}/usr/share/keys/hbsd-update/trusted/" && /bin/cp -f "${temp_dir}/${vulture_update_ca}" "${prefix_dir}/usr/share/keys/hbsd-update/trusted/${vulture_update_ca}"
    /bin/echo "."
}

update_packages() {
    _mnt_temp_dir="$1"

    pkg_env="/usr/bin/env IGNORE_OSVERSION=yes ASSUME_ALWAYS_YES=yes"
    pkg_args="-c $_mnt_temp_dir"

    # Delete me
    # shellcheck disable=SC2086
    $pkg_env /usr/sbin/pkg $pkg_args bootstrap -f || finalize 1 "Could not bootstrap pkg."

    info "[+] Upgrading host system packages..."
    # shellcheck disable=SC2086
    $pkg_env /usr/sbin/pkg $pkg_args unlock vulture-base vulture-gui vulture-haproxy vulture-mongodb vulture-redis vulture-rsyslog
    # shellcheck disable=SC2086
    $pkg_env /usr/sbin/pkg $pkg_args upgrade -f || finalize 1 "Failed to upgrade packages."
    # shellcheck disable=SC2086
    $pkg_env /usr/sbin/pkg $pkg_args lock vulture-base vulture-gui vulture-haproxy vulture-mongodb vulture-redis vulture-rsyslog
    info "[-] Done."

    info "[+] Cleaning pkg cache..."
    # shellcheck disable=SC2086
    $pkg_env /usr/sbin/pkg $pkg_args clean -a
    info "[-] Done."

    for jail in $JAILS_LIST; do
        pkg_args="-c $_mnt_temp_dir/zroot/$jail"

        info "[+] Upgrading $jail's packages..."
        # shellcheck disable=SC2086
        $pkg_env /usr/sbin/pkg $pkg_args upgrade || finalize 1 "Failed to upgrade packages in jail $jail."
        info "[-] Done."

        info "[+] Cleaning $jail pkg cache..."
        # shellcheck disable=SC2086
        $pkg_env /usr/sbin/pkg $pkg_args clean -a
        info "[-] Done."
    done
}

update_zfs_datasets() {
    _zpool="$(get_root_zpool_name)"
    _current_be="$(get_current_BE)"

    # Rename jails datasets
    /usr/sbin/sysrc zfs_enable=YES
    for jail in $JAILS_LIST; do
        # Check name of zfs jails datasets
        if ! /sbin/zfs list -H -oname | grep -q "^${_zpool}/ROOT/$_current_be/$jail\$"; then
            warn "Jail $jail's dataset is in legacy format, it will be renamed. No service interruption needed."
            if [ $_run_ok -ne 1 ]; then
                /usr/bin/printf "Do you want to continue? [yN]: "
                answer=""
                read -r answer
                case "${answer}" in
                    y|Y|yes|Yes|YES)
                    # Do nothing, continue
                    ;;
                    *)  info "Upgrade canceled."
                        exit 0;
                    ;;
                esac
            fi
        else
            continue
        fi

        for dataset in "" /usr /var /var/db /var/log; do
            /sbin/zfs set canmount=noauto "$_zpool/${jail}$dataset"
        done
        /sbin/zfs rename -u "$_zpool/$jail" "$_zpool/ROOT/$_current_be/$jail"
    done

    # Ensure zpool root is not mounted by default
    /sbin/zfs set canmount=noauto "$_zpool"

    # Rename home dataset
    if ! /sbin/zfs list -H -oname | grep -Eq "^${_zpool}/ROOT/$_current_be(/usr)?/home\$"; then
        /sbin/zfs set canmount=noauto "$_zpool/usr/home"
        /sbin/zfs rename -u "$_zpool/usr" "$_zpool/ROOT/$_current_be/usr"
    fi
}

create_and_mount_BE() {
    _mnt_temp_dir="$1"
    _zpool="$(get_root_zpool_name)"

    # Lock mongodb to prevent dataset corruption
    exec_mongo "db.fsyncLock()" > /dev/null
    /sbin/bectl create -r "$new_be" || info "BE '$new_be' already exists, using it."
    exec_mongo "db.fsyncUnlock()" > /dev/null

    # Mount temporarily cache dir into new BE
    /sbin/zfs snap "$_zpool/var/cache@$new_be"
    /sbin/zfs clone -po "canmount=noauto" -o "mountpoint=$_mnt_temp_dir/var/cache" "$_zpool/var/cache@$new_be" "$_zpool/ROOT/$new_be/var/cache"

    # There is a bug where canmount=off is changed to noauto
    /sbin/zfs set canmount=off "$_zpool/ROOT/$new_be/usr"
    /sbin/zfs set canmount=off "$_zpool/ROOT/$new_be/var"

    /sbin/bectl mount "$new_be" "$_mnt_temp_dir" || finalize 1 "Cannot mount BE '$new_be'."
    # There is a bug where subdatasets is not mounted if parent dataset has canmount=off
    /sbin/mount -t zfs "$_zpool/ROOT/$new_be/usr/home" "$_mnt_temp_dir/usr/home"
    /sbin/mount -t zfs "$_zpool/ROOT/$new_be/var/cache" "$_mnt_temp_dir/var/cache"
}

usage() {
    /bin/echo "USAGE ${0} [-DrVy]"
    /bin/echo "OPTIONS:"
    /bin/echo "	-D	only download OS upgrades and packages in BE"
    /bin/echo "	-r	auto reboot after upgrade has complete"
    /bin/echo "	-V	select OS version between 14 and 15 (default: 15)"
    /bin/echo "	-y	start the upgrade whitout asking for user confirmation (implicit consent)"
    exit 1
}

check_preconditions() {
    if [ "$(/usr/bin/id -u)" != "0" ]; then
        error_and_exit "This script must be run as root."
    fi

    # Show necessary packages to be updated
    if /usr/sbin/pkg version -qRl '<' | grep 'vulture-' > /dev/null; then
        /usr/bin/printf "${COLOR_RED}"
        /usr/sbin/pkg version -qRl '<' | grep 'vulture-'
        /usr/bin/printf "${COLOR_OFF}"
        finalize 1 "Some packages are not up to date, please run 'vlt-admin upgrade-pkg' before trying to migrate."
    fi

    # Check remaining disk space larger than 8GB
    if [ "$(/sbin/zpool list -Hpo free)" -lt 8000000000 ]; then
        finalize 1 "Free disk space is insufficient."
    fi

    # Check mongodb service is updated
    _current_mongodb_package="$(pkg -j mongodb info -Ex "mongodb[0-9]+")"
    _current_mongodb_package="${_current_mongodb_package%-*}"
    if [ "${_current_mongodb_package}" != "${target_mongodb_version}" ]; then
        finalize 1 "Wrong mongodb version '${_current_mongodb_package}', please upgrade"
    fi
}

initialize() {
    info "[$(date -u -Iseconds)] Upgrade script started!"

    trap 'finalize 1 "Interruption catched!"' INT

    if [ -f /etc/rc.conf.proxy ]; then
        . /etc/rc.conf.proxy
        export http_proxy="${http_proxy}"
        export https_proxy="${https_proxy}"
        export ftp_proxy="${ftp_proxy}"
    fi

    # Create temporary directory if it does not exist
    /bin/mkdir -p $temp_dir || info "Temp directory exists, keeping it."

    # Fix jails nameserver
    for jail in $JAILS_LIST; do
        case "$jail" in
            mongodb) /bin/echo "nameserver 127.0.0.2" > "/zroot/${jail}/etc/resolv.conf" ;;
            redis) /bin/echo "nameserver 127.0.0.3" > "/zroot/${jail}/etc/resolv.conf" ;;
            rsyslog) /bin/echo "nameserver 127.0.0.4" > "/zroot/${jail}/etc/resolv.conf" ;;
            haproxy) /bin/echo "nameserver 127.0.0.5" > "/zroot/${jail}/etc/resolv.conf" ;;
            apache) /bin/echo "nameserver 127.0.0.6" > "/zroot/${jail}/etc/resolv.conf" ;;
            portal) /bin/echo "nameserver 127.0.0.7" > "/zroot/${jail}/etc/resolv.conf" ;;
            *) ;;
        esac
    done
}

finalize() {
    # set default in case err_code is not specified
    err_code=${1:-0}
    err_message=$2

    if get_BEs | grep -q "$new_be"; then
        info "[+] Unmounting BE..."
        for jail in $JAILS_LIST; do
            /sbin/umount "$mnt_temp_dir/zroot/$jail/.jail_system" 2>/dev/null
        done
        /sbin/umount "$mnt_temp_dir/dev/fd" "$mnt_temp_dir/dev" "$mnt_temp_dir/tmp" "$mnt_temp_dir/proc" 2>/dev/null
        /sbin/bectl umount -f "$new_be"
        /sbin/zfs destroy -r "vulture/ROOT/$new_be/var"
        /sbin/zfs destroy "vulture/var/cache@$new_be"
        info "[-] Done"
    fi

    if [ -n "$err_message" ]; then
        if get_BEs | grep -q "$new_be"; then
            info "[+] Cleaning BE..."
            /sbin/bectl destroy -F "$new_be" || error "[!] Unable to destroy BE '$new_be'."
            info "[-] Done"
        fi

        error_and_exit "\n[!] ${err_message}\n"
    fi

    if [ $download_only -eq 0 ]; then
        info "[+] Cleaning temporary dir..."
        /bin/rm -rf "$temp_dir"
        info "[-] Done"
    fi

    info "[$(date -u -Iseconds)] Upgrade script finished!"

    # has_pending_BE return 1 if there is a pending BE
    if ! has_pending_BE && [ $auto_reboot -eq 1 ]; then
        warn "[+] Rebooting system in 30 seconds."
        /sbin/shutdown -r +30s
    fi

    exit "$err_code"
}


if [ "$(uname -r | cut -d'.' -f1)" -ge "${major_version}" ]; then
    info "Your system seems to already be on HBSD${major_version}, nothing to do!"
    reset_motd
    exit 0
fi

while getopts "DrV:y" flag; do
    case "${flag}" in
        D) download_only=1;
        ;;
        r) auto_reboot=1;
        ;;
        V) major_version=${OPTARG};
        ;;
        y) _run_ok=1;
        ;;
        *) usage;
        ;;
    esac
done

if [ $download_only -eq 0 ]; then
    info "Upgrades of the base system, jails and packages will be installed in the BE '$new_be'."
    if [ $_run_ok -ne 1 ]; then
        /usr/bin/printf "Do you want to upgrade your node? [yN]: "
        answer=""
        read -r answer
        case "${answer}" in
            y|Y|yes|Yes|YES)
            # Do nothing, continue
            ;;
            *)  info "Upgrade canceled."
                exit 0;
            ;;
        esac
    fi
fi

check_preconditions
initialize

download_system_update /

if [ $download_only -eq 0 ]; then
    # Fix pam.d
    if [ -d "$mnt_temp_dir/.jail_system" ] && [ ! -h "$mnt_temp_dir/zroot/apache/etc/pam.d" ]; then
        /bin/rm -r "$mnt_temp_dir"/zroot/*/etc/pam.d || finalize 1 "Unable to fix pam.d, are jails datasets mounted?"
        for jail in $JAILS_LIST; do
            /bin/ln -s ../.jail_system/etc/pam.d "$mnt_temp_dir/zroot/$jail/etc/pam.d"
        done
    fi

    update_zfs_datasets

    mnt_temp_dir=$(mktemp -d)
    create_and_mount_BE "$mnt_temp_dir"

    info "[+] Updating host system..."
    update_system "$mnt_temp_dir"
    chmod 1777 "$mnt_temp_dir/tmp" "$mnt_temp_dir/var/tmp"
    info "[-] Done updating host system."

    for jail in $JAILS_LIST; do
        info "[+] Updating jail $jail..."
        update_system "$mnt_temp_dir" "$jail"
        info "[-] Done updating jail $jail."
    done

    # Mounting all needed filesystems
    /sbin/mount -t devfs devfs "$mnt_temp_dir/dev"
    /sbin/mount -t tmpfs tmpfs "$mnt_temp_dir/tmp"
    /sbin/mount -t fdescfs fdesc "$mnt_temp_dir/dev/fd"
    /sbin/mount -t procfs proc "$mnt_temp_dir/proc"
    /sbin/sysctl hardening.harden_rtld=0

    if [ -d "$mnt_temp_dir/.jail_system" ]; then
        for jail in $JAILS_LIST; do
            /sbin/mount -t nullfs "$mnt_temp_dir/.jail_system" "$mnt_temp_dir/zroot/$jail/.jail_system" || finalize 1 "Unable to mount .jail_system."
        done
    fi

    update_packages "$mnt_temp_dir"

    reset_motd
    /usr/bin/printf "\033[38;5;10mYour system is now on HardenedBSD ${major_version}, welcome back!\033[0m\n" >> "$mnt_temp_dir/etc/motd.template"

    /sbin/bectl activate "$new_be" || finalize 1 "Unable to activate BE, try to do it manually."
else
    download_packages /
fi

finalize 0
