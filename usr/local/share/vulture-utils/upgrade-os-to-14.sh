#!/usr/bin/env sh


. /usr/local/share/vulture-utils/common.sh

SCRIPT=$(realpath "$0")

COLOR_OFF='\033[0m'
COLOR_RED='\033[0;31m'

temp_dir="/var/tmp/update"
new_be="${SNAPSHOT_PREFIX}HBSD14-$(date -Idate)"
download_only=0
auto_reboot=0
_run_ok=0

download_system_update() {
    _mnt_temp_dir="$1"

    if [ ! -f ${temp_dir}/update.tar ]; then
        /usr/bin/sed -i ".bak" "s/13-stable/14-stable/g" "$_mnt_temp_dir/etc/hbsd-update.conf"
        /home/vlt-adm/system/register_vulture_repos.sh $_mnt_temp_dir

        info "[+] Downloading system update"
        /usr/sbin/hbsd-update -d -t "$temp_dir" -T -f -c $_mnt_temp_dir/etc/hbsd-update.conf || finalize 1  "System update download failed."
        info "[-] Done"
    else
        info "[+] Upgrade file found, nothing to do."
    fi
}

update_system() {
    _mnt_temp_dir="$1"
    _jail="$2"
    _options=""

    if [ -n "$_jail" ] ; then
        _options="-n"
        if [ -d $_mnt_temp_dir/.jail_system ]; then
            _path="$_mnt_temp_dir/.jail_system"
        else
            _path="$_mnt_temp_dir/zroot/$jail"
        fi
    else
        _path="$_mnt_temp_dir"
    fi

    /usr/bin/sed -i ".bak" "s/13-stable/14-stable/g" "$_path/etc/hbsd-update.conf"
    /home/vlt-adm/system/register_vulture_repos.sh $_path

    /bin/echo "[+] Updating base system..."
    # shellcheck disable=SC2086
    /usr/bin/yes "mf" | /usr/sbin/hbsd-update -t "$temp_dir" -T -D -r $_path -c $_path/etc/hbsd-update.conf $_options || finalize 1 "System update failed"
    /bin/echo "[-] Done with update"
}

download_packages() {
    _mnt_temp_dir="$1"

    chroot_and_env="/usr/sbin/chroot $_mnt_temp_dir /usr/bin/env IGNORE_OSVERSION=yes ASSUME_ALWAYS_YES=yes"
    if [ $download_only -eq 1 ]; then
        chroot_and_env="$chroot_and_env ABI=FreeBSD:14:amd64"
    fi

    /bin/echo "[+] Updating root pkg repository catalogue"
    $chroot_and_env /usr/sbin/pkg update -f || finalize 1 "Could not update list of packages"
    /bin/echo "[-] Done"

    /bin/echo "[+] Clear pkg cache before fetching"
    $chroot_and_env /usr/sbin/pkg clean -a || finalize 1 "Could not clear pkg cache"
    /bin/echo "[-] Done"

    info "[+] Fetching host's packages"
    $chroot_and_env /usr/sbin/pkg unlock vulture-base vulture-gui vulture-haproxy vulture-mongodb vulture-redis vulture-rsyslog
    $chroot_and_env /usr/sbin/pkg fetch -u || finalize 1 "Failed to download packages"
    $chroot_and_env /usr/sbin/pkg lock vulture-base vulture-gui vulture-haproxy vulture-mongodb vulture-redis vulture-rsyslog
    info "[-] Done"

    for jail in $JAILS_LIST; do
        /sbin/mount -t nullfs $_mnt_temp_dir/.jail_system $_mnt_temp_dir/zroot/$jail/.jail_system || finalize 1 "Unable to mount .jail_system"
        $chroot_and_env /usr/sbin/pkg -c /zroot/$jail clean -a || finalize 1 "Could not clear pkg cache for jail $jail"
    
        /bin/echo "[+] Fetching $jail's packages..."
        $chroot_and_env /usr/sbin/pkg -c /zroot/$jail fetch -u || finalize 1 "Failed to download packages for jail $jail"
        /bin/echo "[-] Done"
    
        /sbin/umount $_mnt_temp_dir/zroot/$jail/.jail_system 2>/dev/null
    done
}

update_packages() {
    _mnt_temp_dir="$1"

    chroot_and_env="/usr/sbin/chroot $_mnt_temp_dir /usr/bin/env IGNORE_OSVERSION=yes ASSUME_ALWAYS_YES=yes"

    # Delete me
    $chroot_and_env /usr/sbin/pkg bootstrap -f || finalize 1 "Could not bootstrap pkg"

    info "[+] Upgrading host system packages"
    $chroot_and_env /usr/sbin/pkg unlock vulture-base vulture-gui vulture-haproxy vulture-mongodb vulture-redis vulture-rsyslog
    $chroot_and_env /usr/sbin/pkg upgrade -f || finalize 1 "Failed to upgrade packages"
    $chroot_and_env /usr/sbin/pkg lock vulture-base vulture-gui vulture-haproxy vulture-mongodb vulture-redis vulture-rsyslog
    info "[-] Done"

    /bin/echo "[+] Cleaning pkg cache..."
    $chroot_and_env /usr/sbin/pkg clean -a
    /bin/echo "[-] Done"

    for jail in $JAILS_LIST; do
        info "[+] Upgrading $jail's packages"
        $chroot_and_env /usr/sbin/pkg -c /zroot/$jail upgrade || finalize 1 "Failed to upgrade packages on jail $jail"
        info "[-] Done"

        /bin/echo "[+] Cleaning $jail pkg cache..."
        $chroot_and_env /usr/sbin/pkg -c /zroot/$jail clean -a
        /bin/echo "[-] Done"
    done
}

update_zfs_datasets() {
    _zpool="$(get_root_zpool_name)"
    _current_be="$(get_current_BE)"
    _need_reboot=0

    # Rename jails datasets
    /usr/sbin/sysrc zfs_enable=YES
    /usr/sbin/service vultured stop
    for jail in $JAILS_LIST; do
        # Check name of zfs jails datasets
        if ! zfs_dataset_exists ROOT/$_current_be/$jail; then
            warn "Jail $jail's dataset is in legacy format, it will be renamed and node will need to reboot."
            if [ $_run_ok -ne 1 ]; then
                /usr/bin/printf "Do you want to continue anyway? [yN]: "
                answer=""
                read -r answer
                case "${answer}" in
                    y|Y|yes|Yes|YES)
                    # Do nothing, continue
                    ;;
                    *)  /usr/sbin/service vultured start
                        /bin/echo "Upgrade canceled."
                        exit 0;
                    ;;
                esac
            fi
        else
            continue
        fi

        /home/vlt-os/env/bin/python /home/vlt-os/vulture_os/manage.py toggle_maintenance --on 2>/dev/null

        # Need to stop jail cleanly
        /usr/sbin/service jail stop $jail

        for dataset in "" /usr /var /var/db /var/log; do
            /sbin/zfs set canmount=noauto $_zpool/${jail}$dataset
        done

        /sbin/umount -at nullfs 2>/dev/null
        # /sbin/umount $(mount -lt nullfs | awk "on /zroot\/$jail/ {print \$3}") 2>/dev/null
        # /sbin/umount /zroot/$jail/.jail_system 2>/dev/null
        # /sbin/umount /zroot/$jail/var/db/pki 2>/dev/null
        # if [ "$jail" = "rsyslog" ]; then
        #     /sbin/umount /usr/local/etc/filebeat /zroot/apache/usr/local/etc/filebeat
        # fi
        /sbin/zfs rename -f $_zpool/$jail $_zpool/ROOT/$_current_be/$jail

        # _need_reboot=1
    done

    # Rename home dataset
    if ! zfs_dataset_exists ROOT/$_current_be/usr/home; then
        /sbin/umount /zroot/rsyslog/home/vlt-os/vulture_os/services/rsyslogd/config /zroot/portal/home/vlt-os /zroot/apache/home/vlt-os 2>/dev/null
        /sbin/zfs set canmount=noauto $_zpool/usr/home
        /sbin/zfs rename -f $_zpool/usr $_zpool/ROOT/$_current_be/usr

        # _need_reboot=1
    fi

    /sbin/mount -aL
    /home/vlt-os/env/bin/python /home/vlt-os/vulture_os/manage.py toggle_maintenance --off 2>/dev/null
    /usr/sbin/service vultured start
    /usr/sbin/service jail start

    # if [ $_need_reboot -eq 1 ]; then
    #     if [ $_run_ok -eq 1 ]; then
    #         restart_and_continue
    #     else
    #         error_and_blink "[!] You have to reboot to apply changes and restart manually the upgrade."
    #         finalize 0
    #     fi
    # fi
}

create_and_mount_BE() {
    _mnt_temp_dir="$1"

    # Lock mongodb to prevent dataset corruption
    exec_mongo "db.fsyncLock()" > /dev/null
    /sbin/bectl create -r $new_be || info "BE '$new_be' already exists."
    exec_mongo "db.fsyncUnlock()" > /dev/null
    # There is a bug where canmount=off is changed to noauto
    /sbin/zfs set canmount=off "$(get_root_zpool_name)/ROOT/$new_be/usr"

    /sbin/bectl mount $new_be $_mnt_temp_dir || finalize 1 "Cannot mount BE '$new_be'."
    if [ $download_only -eq 0 ]; then
        # There is a bug where subdatasets is not mounted if parent dataset has canmount=off
        /sbin/mount -t zfs "$(get_root_zpool_name)/ROOT/$new_be/usr/home" $_mnt_temp_dir/usr/home
    fi
}

restart_and_continue() {
    /bin/echo "[+] Setting up startup script to continue upgrade..."
    # enable script to be run on startup
    /bin/echo "@reboot root sleep 60 && /bin/sh $SCRIPT -y" > "/etc/cron.d/vulture_update" || finalize 1 "Failed to setup startup script"
    # Add a temporary message to end of MOTD to warn about the ongoing upgrade
    reset_motd
    add_to_motd "\033[5m\033[38;5;196mUpgrade in progress, your machine will reboot shortly, please wait patiently!\033[0m"
    /usr/bin/touch ${temp_dir}/upgrading
    /bin/echo "[-] Ok"
    /bin/echo "[+] Rebooting system"
    /sbin/shutdown -r now
    /bin/echo "[-] Ok"
    exit 0
}

restart_in_be_and_continue() {
    /bin/echo "[+] Setting up startup script to continue upgrade in BE..."
    # enable script to be run on startup
    tmp_be_mount="$(/usr/bin/mktemp -d)"
    /sbin/bectl mount "$new_be" "$tmp_be_mount" || finalize 1 "Could not mount Boot Environment"
    /bin/echo "@reboot root sleep 60 && /bin/sh $SCRIPT -y" > "${tmp_be_mount}/etc/cron.d/vulture_update" || finalize 1 "Failed to setup startup script"
    # Add a temporary message to end of MOTD to warn about the ongoing upgrade
    /usr/bin/sed -i '' '$s/.*/[5m[38;5;196mUpgrade in progress, your machine will reboot shortly, please wait patiently![0m/' "${tmp_be_mount}/etc/motd.template"
    /usr/bin/sed -i '' 's+welcome=/etc/motd+welcome=/var/run/motd+' "${tmp_be_mount}/etc/login.conf"
    /usr/bin/cap_mkdb "${tmp_be_mount}/etc/login.conf"
    /sbin/bectl umount "$new_be"
    /usr/bin/touch "${tmp_be_mount}/${temp_dir}/upgrading"
    /bin/echo "[-] Ok"
    /bin/echo "[+] Rebooting system"
    /sbin/shutdown -r now
    /bin/echo "[-] Ok"
    exit 0
}

clean_and_restart() {
    /bin/echo "[+] Cleaning up..."
    /bin/echo "@reboot root sleep 60 && /home/vlt-os/env/bin/python /home/vlt-os/vulture_os/manage.py toggle_maintenance --off && rm /etc/cron.d/vulture_update" > "/etc/cron.d/vulture_update"

    /bin/echo "[+] Cleaning temporary dir..."
    /bin/rm -rf $temp_dir
    /bin/echo "[-] Done"

    warn "WARNING: a new Boot Environment was created during the upgrade, please review existing BEs and delete those no longer necessary!"
    /sbin/bectl list -a

    info "[$(date -u -Iseconds)] Upgrade script finished!"

    /bin/echo "[+] Rebooting system"
    /sbin/shutdown -r now

    exit 0
}

usage() {
    /bin/echo "USAGE ${0} [-y]"
    /bin/echo "OPTIONS:"
    /bin/echo "	-D	only download OS upgrades and packages in BE"
    /bin/echo "	-r	auto reboot after upgrade has complete"
    /bin/echo "	-y	start the upgrade whitout asking for user confirmation (implicit consent)"
    exit 1
}

check_preconditions() {
    if [ "$(/usr/bin/id -u)" != "0" ]; then
        /bin/echo "This script must be run as root" 1>&2
        exit 1
    fi
    # Show necessary packages to be updated
    if /usr/sbin/pkg version -qRl '<' | grep 'vulture-' > /dev/null; then
        /usr/bin/printf "${COLOR_RED}"
        /usr/sbin/pkg version -qRl '<' | grep 'vulture-'
        /usr/bin/printf "${COLOR_OFF}"
        finalize 1 "Some packages are not up to date, please run 'vlt-admin upgrade-pkg' before trying to migrate"
    fi
    # Check remaining disk space larger than 8GB
    if [ "$(/sbin/zpool list -Hpo free)" -lt 8000000000 ]; then
        finalize 1 "Free disk space is insufficient"
    fi
}

initialize() {
    info "[$(date -u -Iseconds)] Upgrade script started!"

    trap finalize INT

    if [ -f /etc/rc.conf.proxy ]; then
        . /etc/rc.conf.proxy
        export http_proxy="${http_proxy}"
        export https_proxy="${https_proxy}"
        export ftp_proxy="${ftp_proxy}"
    fi

    # Create temporary directory if it does not exist
    /bin/mkdir -p $temp_dir || /bin/echo "Temp directory exists, keeping"

    # Fix jails nameserver
    for jail in $JAILS_LIST; do
        case "$jail" in
            mongodb)
                /bin/echo "nameserver 127.0.0.2" > /zroot/${jail}/etc/resolv.conf
                ;;
            redis)
                /bin/echo "nameserver 127.0.0.3" > /zroot/${jail}/etc/resolv.conf
                ;;
            rsyslog)
                /bin/echo "nameserver 127.0.0.4" > /zroot/${jail}/etc/resolv.conf
                ;;
            haproxy)
                /bin/echo "nameserver 127.0.0.5" > /zroot/${jail}/etc/resolv.conf
                ;;
            apache)
                /bin/echo "nameserver 127.0.0.6" > /zroot/${jail}/etc/resolv.conf
                ;;
            portal)
                /bin/echo "nameserver 127.0.0.7" > /zroot/${jail}/etc/resolv.conf
                ;;
            *)
                ;;
        esac
    done
}

finalize() {
    # set default in case err_code is not specified
    err_code=${1:-0}
    err_message=$2

    if [ $download_only -eq 0 ]; then
        /bin/echo "[+] Cleaning temporary dir..."
        /bin/rm -rf "$temp_dir"
        /bin/echo "[-] Done."
    fi

    if get_BEs | grep -q $new_be; then
        /bin/echo "[+] Unmounting BE..."
        for jail in $JAILS_LIST; do
            /sbin/umount $mnt_temp_dir/zroot/$jail/.jail_system 2>/dev/null
        done
        /sbin/umount $mnt_temp_dir/dev/fd $mnt_temp_dir/dev $mnt_temp_dir/tmp $mnt_temp_dir/proc 2>/dev/null
        /sbin/bectl umount -f $new_be
        /bin/echo "[-] Done"
    fi

    /home/vlt-os/env/bin/python /home/vlt-os/vulture_os/manage.py toggle_maintenance --off 2>/dev/null

    if [ -n "$err_message" ]; then
        if get_BEs | grep -q $new_be; then
            /bin/echo "[+] Cleaning BE..."
            /sbin/bectl destroy -F $new_be || error "[!] Unable to destroy BE '$new_be'"
            /bin/echo "[-] Done"
        fi

        /bin/echo ""
        error_and_exit "[!] ${err_message}\n"
    fi

    info "[$(date -u -Iseconds)] Upgrade script finished!"

    if has_pending_BE && [ $auto_reboot -eq 1 ]; then
        /bin/echo "[+] Rebooting system"
        /sbin/shutdown -r now
    fi

    exit $err_code
}


if [ "$(uname -K)" -gt 1400000 ]; then
    /bin/echo "Your system seems to already be on HBSD14, nothing to do!"
    reset_motd
    exit 0
fi

while getopts "Dy" flag;
do
    case "${flag}" in
        D) download_only=1;
        ;;
        r) auto_reboot=1;
        ;;
        y) _run_ok=1;
        ;;
        *) usage;
        ;;
    esac
done

if [ $download_only -eq 1 ]; then
    check_preconditions
    initialize
    if ! zfs_dataset_exists ROOT/$(get_current_BE)/usr/home; then
        warn "ZFS dataset is in legacy format, cannot download only needed files."
        error "If you continue, needed changes will be applied and node will need to reboot."
        if [ $_run_ok -ne 1 ]; then
            /usr/bin/printf "Do you want to continue anyway? [yN]: "
            answer=""
            read -r answer
            case "${answer}" in
                y|Y|yes|Yes|YES) update_zfs_datasets
                ;;
                *)  /bin/echo "Upgrade canceled."
                    exit 0;
                ;;
            esac
        fi
    fi
    mnt_temp_dir=$(mktemp -d)
    create_and_mount_BE $mnt_temp_dir
    download_system_update $mnt_temp_dir
    /sbin/mount -t devfs devfs $mnt_temp_dir/dev
    download_packages $mnt_temp_dir
    /sbin/umount $mnt_temp_dir/dev
    finalize 0
fi

info "Upgrades of the base system, jails and packages will be installed in the BE '$new_be'."
if [ $_run_ok -ne 1 ]; then
    /usr/bin/printf "Do you want to upgrade your node? [yN]: "
    answer=""
    read -r answer
    case "${answer}" in
        y|Y|yes|Yes|YES)
        # Do nothing, continue
        ;;
        *)  /bin/echo "Upgrade canceled."
            exit 0;
        ;;
    esac
fi

# Automatically continue upgrade if a reboot occured
if [ -f ${temp_dir}/upgrading ] && [ $_run_ok -eq 1 ]; then
    log_file=/var/log/upgrade-to-14.log
    /bin/echo "Output will be sent to $log_file"

    exec 3>&1 4>&2
    trap 'exec 2>&4 1>&3' 0 1 2 3
    exec 1>>$log_file 2>&1
fi

check_preconditions
initialize

update_zfs_datasets

mnt_temp_dir=$(mktemp -d)
create_and_mount_BE $mnt_temp_dir

# Fix pam.d
if [ -d $mnt_temp_dir/.jail_system ] && [ ! -h "$mnt_temp_dir/zroot/apache/etc/pam.d" ]; then
    /bin/rm -vr $mnt_temp_dir/zroot/*/etc/pam.d || finalize 1 "Unable to fix pam.d, are jails datasets mounted?"
    for jail in apache portal haproxy mongodb rsyslog redis; do
        /bin/ln -vs ../.jail_system/etc/pam.d $mnt_temp_dir/zroot/$jail/etc/pam.d
    done
fi

info "[+] Updating host system"
download_system_update $mnt_temp_dir
update_system $mnt_temp_dir
chmod 1777 $mnt_temp_dir/tmp $mnt_temp_dir/var/tmp
info "[-] Done updating host system"

for jail in $JAILS_LIST; do
    info "[+] Updating jail $jail"
    update_system $mnt_temp_dir $jail
    info "[-] Done updating jail $jail"
done

# Mounting all needed filesystems
/sbin/mount -t devfs devfs $mnt_temp_dir/dev
/sbin/mount -t tmpfs tmpfs $mnt_temp_dir/tmp
/sbin/mount -t fdescfs fdesc $mnt_temp_dir/dev/fd
/sbin/mount -t procfs proc $mnt_temp_dir/proc
/sbin/sysctl hardening.harden_rtld=0

if [ -d $mnt_temp_dir/.jail_system ]; then
    for jail in $JAILS_LIST; do
        /sbin/mount -t nullfs $mnt_temp_dir/.jail_system $mnt_temp_dir/zroot/$jail/.jail_system || finalize "Unable to mount .jail_system"
    done
fi

# download_packages $mnt_temp_dir
update_packages $mnt_temp_dir

reset_motd
/usr/bin/printf "\033[38;5;10mYour system is now on HardenedBSD 14, welcome back!\033[0m\n" >> $mnt_temp_dir/etc/motd.template

/sbin/bectl activate -t $new_be || finalize 1 "Unable to activate BE, try to do it manually."

finalize 0
# restart_and_continue
# clean_and_restart
