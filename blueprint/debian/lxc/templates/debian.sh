#!/bin/bash

#
# lxc: linux Container library

# Authors:
# Daniel Lezcano <daniel.lezcano@free.fr>

# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2.1 of the License, or (at your option) any later version.

# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.

# You should have received a copy of the GNU Lesser General Public
# License along with this library; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA

# Detect use under userns (unsupported)
for arg in "$@"; do
    [ "$arg" = "--" ] && break
    if [ "$arg" = "--mapped-uid" -o "$arg" = "--mapped-gid" ]; then
        echo "This template can't be used for unprivileged containers." 1>&2
        echo "You may want to try the \"download\" template instead." 1>&2
        exit 1
    fi
done

# Make sure the usual locations are in PATH
export PATH=$PATH:/usr/sbin:/usr/bin:/sbin:/bin
export GREP_OPTIONS=""

MIRROR=${MIRROR:-http://deb.debian.org/debian}
SECURITY_MIRROR=${SECURITY_MIRROR:-http://security.debian.org/}
# region @pionuxos
# LOCALSTATEDIR="@LOCALSTATEDIR@"
# LXC_TEMPLATE_CONFIG="@LXCTEMPLATECONFIG@"
LOCALSTATEDIR="/var"
LXC_TEMPLATE_CONFIG="/usr/share/lxc/config"
# endregion
# Allows the lxc-cache directory to be set by environment variable
LXC_CACHE_PATH=${LXC_CACHE_PATH:-"$LOCALSTATEDIR/cache/lxc"}

configure_debian()
{
    rootfs=$1
    hostname=$2
    num_tty=$3

    # squeeze only has /dev/tty and /dev/tty0 by default,
    # therefore creating missing device nodes for tty1-4.
    for tty in $(seq 1 "$num_tty"); do
        if [ ! -e "$rootfs/dev/tty$tty" ]; then
            mknod "$rootfs/dev/tty$tty" c 4 "$tty"
        fi
    done

    # configure the inittab
    cat <<EOF > $rootfs/etc/inittab
id:3:initdefault:
si::sysinit:/etc/init.d/rcS
l0:0:wait:/etc/init.d/rc 0
l1:1:wait:/etc/init.d/rc 1
l2:2:wait:/etc/init.d/rc 2
l3:3:wait:/etc/init.d/rc 3
l4:4:wait:/etc/init.d/rc 4
l5:5:wait:/etc/init.d/rc 5
l6:6:wait:/etc/init.d/rc 6
# Normally not reached, but fallthrough in case of emergency.
z6:6:respawn:/sbin/sulogin
1:2345:respawn:/sbin/getty 38400 console
$(for tty in $(seq 1 "$num_tty"); do echo "c${tty}:12345:respawn:/sbin/getty 38400 tty${tty} linux" ; done;)
p6::ctrlaltdel:/sbin/init 6
p0::powerfail:/sbin/init 0
EOF

    # symlink mtab
    [ -e "$rootfs/etc/mtab" ] && rm "$rootfs/etc/mtab"
    ln -s /proc/self/mounts "$rootfs/etc/mtab"

    # disable selinux in debian
    mkdir -p "$rootfs/selinux"
    echo 0 > "$rootfs/selinux/enforce"

    # configure the network using the dhcp
    cat <<EOF > $rootfs/etc/network/interfaces
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

    # set the hostname
    cat <<EOF > $rootfs/etc/hostname
$hostname
EOF

    # reconfigure some services

    # but first reconfigure locales - so we get no noisy perl-warnings
    if [ -z "$LANG" ] || echo $LANG | grep -E -q "^C(\..+)*$"; then
        cat >> "$rootfs/etc/locale.gen" << EOF
en_US.UTF-8 UTF-8
EOF
        chroot "$rootfs" locale-gen en_US.UTF-8 UTF-8
        chroot "$rootfs" update-locale LANG=en_US.UTF-8
    else
        encoding=$(echo "$LANG" | cut -d. -f2)
        chroot "$rootfs" sed -e "s/^# \(${LANG} ${encoding}\)/\1/" \
            -i /etc/locale.gen 2> /dev/null
        cat >> "$rootfs/etc/locale.gen" << EOF
$LANG $encoding
EOF
        chroot "$rootfs" locale-gen "$LANG" "$encoding"
        chroot "$rootfs" update-locale LANG="$LANG"
    fi

    # remove pointless services in a container
    chroot "$rootfs" /usr/sbin/update-rc.d -f checkroot.sh disable
    chroot "$rootfs" /usr/sbin/update-rc.d -f umountfs disable
    chroot "$rootfs" /usr/sbin/update-rc.d -f hwclock.sh disable
    chroot "$rootfs" /usr/sbin/update-rc.d -f hwclockfirst.sh disable

    # generate new SSH keys
    if [ -x "$rootfs/var/lib/dpkg/info/openssh-server.postinst" ]; then
        cat > "$rootfs/usr/sbin/policy-rc.d" << EOF
#!/bin/sh
exit 101
EOF
        chmod +x "$rootfs/usr/sbin/policy-rc.d"

        if [ -f "$rootfs/etc/init/ssh.conf" ]; then
            mv "$rootfs/etc/init/ssh.conf" "$rootfs/etc/init/ssh.conf.disabled"
        fi

        rm -f "$rootfs/etc/ssh/"ssh_host_*key*

        DPKG_MAINTSCRIPT_PACKAGE=openssh DPKG_MAINTSCRIPT_NAME=postinst chroot "$rootfs" /var/lib/dpkg/info/openssh-server.postinst configure
        sed -i "s/root@$(hostname)/root@$hostname/g" "$rootfs/etc/ssh/"ssh_host_*.pub

        if [ -f "$rootfs/etc/init/ssh.conf.disabled" ]; then
            mv "$rootfs/etc/init/ssh.conf.disabled" "$rootfs/etc/init/ssh.conf"
        fi

        rm -f "$rootfs/usr/sbin/policy-rc.d"
    fi

    # set initial timezone as on host
    if [ -f /etc/timezone ]; then
        cat /etc/timezone > "$rootfs/etc/timezone"
        chroot "$rootfs" dpkg-reconfigure -f noninteractive tzdata
    elif [ -f /etc/sysconfig/clock ]; then
        . /etc/sysconfig/clock
        echo "$ZONE" > "$rootfs/etc/timezone"
        chroot "$rootfs" dpkg-reconfigure -f noninteractive tzdata
    else
        echo "Timezone in container is not configured. Adjust it manually."
    fi

    return 0
}

write_sourceslist()
{
    local rootfs="$1";  shift
    local release="$1"; shift
    local arch="$1";    shift

    local prefix="deb"
    if [ -n "${arch}" ]; then
        prefix="deb [arch=${arch}]"
    fi

    if [ "$mainonly" = 1 ]; then
      non_main=''
    else
      non_main=' contrib non-free'
    fi

    cat >> "${rootfs}/etc/apt/sources.list" << EOF
${prefix} $MIRROR          ${release}         main${non_main}
EOF

    if [ "$release" != "unstable" -a "$release" != "sid" ]; then
      cat >> "${rootfs}/etc/apt/sources.list" << EOF
${prefix} $SECURITY_MIRROR ${release}/updates main${non_main}
EOF
    fi
}

install_packages()
{
    local rootfs="$1"; shift
    local packages="$*"

    chroot "${rootfs}" apt-get update
    if [ -n "${packages}" ]; then
        chroot "${rootfs}" apt-get install --force-yes -y --no-install-recommends ${packages}
    fi
}

configure_debian_systemd()
{
    path=$1
    rootfs=$2
    config=$3
    num_tty=$4

    # just in case systemd is not installed
    mkdir -p "${rootfs}/lib/systemd/system"
    mkdir -p "${rootfs}/etc/systemd/system/getty.target.wants"

    # Fix getty-static-service as debootstrap does not install dbus
    if [ -e "$rootfs//lib/systemd/system/getty-static.service" ] ; then
        local tty_services
        tty_services=$(for i in $(seq 2 "$num_tty"); do echo -n "getty@tty${i}.service "; done; )
        sed 's/ getty@tty.*/'" $tty_services "'/g' \
                "$rootfs/lib/systemd/system/getty-static.service" |  \
                sed 's/\(tty2-tty\)[5-9]/\1'"${num_tty}"'/g' > "$rootfs/etc/systemd/system/getty-static.service"
    fi

    # This function has been copied and adapted from lxc-fedora
    rm -f "${rootfs}/etc/systemd/system/default.target"
    # region @pionuxos
    # chroot "${rootfs}" ln -s /dev/null /etc/systemd/system/udev.service
    # chroot "${rootfs}" ln -s /dev/null /etc/systemd/system/systemd-udevd.service
    # endregion
    chroot "${rootfs}" ln -s /lib/systemd/system/multi-user.target /etc/systemd/system/default.target
    # Setup getty service on the ttys we are going to allow in the
    # default config.  Number should match lxc.tty
    ( cd "${rootfs}/etc/systemd/system/getty.target.wants"
        for i in $(seq 1 "$num_tty") ; do ln -sf ../getty\@.service getty@tty"${i}".service; done )

    # Since we use static-getty.target; we need to mask container-getty@.service generated by
    # container-getty-generator, so we don't get multiple instances of agetty running.
    # See https://github.com/lxc/lxc/issues/520 and https://github.com/lxc/lxc/issues/484
    ( cd "${rootfs}/etc/systemd/system/getty.target.wants"
        for i in $(seq 0 "$num_tty"); do ln -sf /dev/null container-getty\@"${i}".service; done )

    return 0
}

cleanup()
{
    rm -rf "$cache/partial-$release-$arch"
    rm -rf "$cache/rootfs-$release-$arch"
}

download_debian()
{
    case "$release" in
      wheezy)
        init=sysvinit
        iproute=iproute
        ;;
      *)
        init=init
        iproute=iproute2
        ;;
    esac
    packages=\
$init,\
ifupdown,\
locales,\
dialog,\
isc-dhcp-client,\
netbase,\
net-tools,\
$iproute,\
openssh-server

    cache=$1
    arch=$2
    release=$3

    trap cleanup EXIT SIGHUP SIGINT SIGTERM

    # Create the cache
    mkdir -p "$cache"

    # If debian-archive-keyring isn't installed, fetch GPG keys directly
    releasekeyring=/usr/share/keyrings/debian-archive-keyring.gpg
    if [ ! -f $releasekeyring ]; then
        releasekeyring="$cache/archive-key.gpg"
        case $release in
            "wheezy")
                gpgkeyname="archive-key-7.0"
                ;;
            *)
                gpgkeyname="archive-key-8"
                ;;
        esac
        wget https://ftp-master.debian.org/keys/${gpgkeyname}.asc -O - --quiet \
            | gpg --import --no-default-keyring --keyring="${releasekeyring}"
    fi
    # check the mini debian was not already downloaded
    mkdir -p "$cache/partial-$release-$arch"
    if [ $? -ne 0 ]; then
        echo "Failed to create '$cache/partial-$release-$arch' directory"
        return 1
    fi

    # download a mini debian into a cache
    echo "Downloading debian minimal ..."
    # region @pionuxos
    # debootstrap --verbose --variant=minbase --arch="$arch" \
    #     --include="$packages" --keyring="${releasekeyring}" \
    #     "$release" "$cache/partial-$release-$arch" "$MIRROR"
    qemu-debootstrap --verbose --variant=minbase --arch="$arch" \
        --include="$packages" --keyring="${releasekeyring}" \
        "$release" "$cache/partial-$release-$arch" "$MIRROR"
    # endregion
    if [ $? -ne 0 ]; then
        echo "Failed to download the rootfs, aborting."
        return 1
    fi

    mv "$1/partial-$release-$arch" "$1/rootfs-$release-$arch"
    echo "Download complete."
    trap EXIT
    trap SIGINT
    trap SIGTERM
    trap SIGHUP

    return 0
}

copy_debian()
{
    cache=$1
    arch=$2
    rootfs=$3
    release=$4

    # make a local copy of the minidebian
    echo -n "Copying rootfs to $rootfs..."
    mkdir -p "$rootfs"
    rsync -SHaAX "$cache/rootfs-$release-$arch"/ "$rootfs"/ || return 1
    return 0
}

install_debian()
{
    rootfs=$1
    release=$2
    arch=$3
    cache="$4/debian"
    mkdir -p $LOCALSTATEDIR/lock/subsys/
    (
        flock -x 9
        if [ $? -ne 0 ]; then
            echo "Cache repository is busy."
            return 1
        fi

        echo "Checking cache download in $cache/rootfs-$release-$arch ... "
        if [ ! -e "$cache/rootfs-$release-$arch" ]; then
            download_debian "$cache" "$arch" "$release"
            if [ $? -ne 0 ]; then
                echo "Failed to download 'debian base'"
                return 1
            fi
        fi

        copy_debian "$cache" "$arch" "$rootfs" "$release"
        if [ $? -ne 0 ]; then
            echo "Failed to copy rootfs"
            return 1
        fi

        return 0

        ) 9>$LOCALSTATEDIR/lock/subsys/lxc-debian

    return $?
}

copy_configuration()
{
    path=$1
    rootfs=$2
    hostname=$3
    arch=$4
    num_tty=$5

    # Generate the configuration file
    # if there is exactly one veth network entry, make sure it has an
    # associated hwaddr.
    nics=$(grep -ce '^lxc\.network\.type[ \t]*=[ \t]*veth' "$path/config")
    if [ "$nics" -eq 1 ]; then
        grep -q "^lxc.network.hwaddr" "$path/config" || sed -i -e "/^lxc\.network\.type[ \t]*=[ \t]*veth/a lxc.network.hwaddr = 00:16:3e:$(openssl rand -hex 3| sed 's/\(..\)/\1:/g; s/.$//')" "$path/config"
    fi

    ## Add all the includes
    echo "" >> "$path/config"
    echo "# Common configuration" >> "$path/config"
    if [ -e "${LXC_TEMPLATE_CONFIG}/debian.common.conf" ]; then
        echo "lxc.include = ${LXC_TEMPLATE_CONFIG}/debian.common.conf" >> "$path/config"
    fi
    if [ -e "${LXC_TEMPLATE_CONFIG}/debian.${release}.conf" ]; then
        echo "lxc.include = ${LXC_TEMPLATE_CONFIG}/debian.${release}.conf" >> "$path/config"
    fi

    ## Add the container-specific config
    echo "" >> "$path/config"
    echo "# Container specific configuration" >> "$path/config"
    grep -q "^lxc.rootfs" "$path/config" 2> /dev/null || echo "lxc.rootfs = $rootfs" >> "$path/config"

    cat <<EOF >> $path/config
lxc.tty = $num_tty
lxc.utsname = $hostname
lxc.arch = $arch
EOF

    if [ $? -ne 0 ]; then
        echo "Failed to add configuration"
        return 1
    fi

    return 0
}

post_process()
{
    local rootfs="$1";  shift
    local release="$1"; shift
    local arch="$1"; shift
    local hostarch="$1"; shift
    local packages="$*"

    # Disable service startup
    cat > "${rootfs}/usr/sbin/policy-rc.d" << EOF
#!/bin/sh
exit 101
EOF
    chmod +x "${rootfs}/usr/sbin/policy-rc.d"

    # If the container isn't running a native architecture, setup multiarch
    if [ "${arch}" != "${hostarch}" ]; then
        # Test if dpkg supports multiarch
        if ! chroot "$rootfs" dpkg --print-foreign-architectures 2>&1; then
            chroot "$rootfs" dpkg --add-architecture "${hostarch}"
        fi
    fi

    # Write a new sources.list containing both native and multiarch entries
    > "${rootfs}/etc/apt/sources.list"
    if [ "${arch}" = "${hostarch}" ]; then
        write_sourceslist "${rootfs}" "${release}" "${arch}"
    else
        write_sourceslist "${rootfs}" "${release}"
    fi

    # Install Packages in container
    if [ -n "${packages}" ]; then
        local pack_list
        pack_list="${packages//,/ }"
        echo "Installing packages: ${pack_list}"
        install_packages "${rootfs}" "${pack_list}"
    fi

    # Re-enable service startup
    rm "${rootfs}/usr/sbin/policy-rc.d"
    # end
}

clean()
{
    cache=${LXC_CACHE_PATH:-"$LOCALSTATEDIR/cache/lxc/debian"}

    if [ ! -e "$cache" ]; then
        exit 0
    fi

    # lock, so we won't purge while someone is creating a repository
    (
        flock -x 9
        if [ $? != 0 ]; then
            echo "Cache repository is busy."
            exit 1
        fi

        echo -n "Purging the download cache..."
        rm --preserve-root --one-file-system -rf "$cache" && echo "Done." || exit 1
        exit 0

    ) 9>$LOCALSTATEDIR/lock/subsys/lxc-debian
}

usage()
{
    cat <<EOF
Template specific options can be passed to lxc-create after a '--' like this:

  lxc-create --name=NAME [-lxc-create-options] -- [-template-options]

Usage: $1 -h|--help -p|--path=<path> [-c|--clean] [-a|--arch=<arch>] [-r|--release=<release>]
                                     [--mirror=<mirror>] [--security-mirror=<security mirror>]
                                     [--package=<package_name1,package_name2,...>]

Options :

  -h, --help             print this help text
  -p, --path=PATH        directory where config and rootfs of this VM will be kept
  -a, --arch=ARCH        The container architecture. Can be one of: i686, x86_64,
                         amd64, armhf, armel, powerpc. Defaults to host arch.
  -r, --release=RELEASE  Debian release. Can be one of: wheezy, jessie, stretch, buster, sid.
                         Defaults to current stable.
  --mirror=MIRROR        Debian mirror to use during installation. Overrides the MIRROR
                         environment variable (see below).
  --security-mirror=SECURITY_MIRROR
                         Debian mirror to use for security updates. Overrides the
                         SECURITY_MIRROR environment variable (see below).
  --packages=PACKAGE_NAME1,PACKAGE_NAME2,...
                         List of additional packages to install. Comma separated, without space.
  -c, --clean            only clean up the cache and terminate
  --enable-non-free      include also Debian's contrib and non-free repositories.

Environment variables:

  MIRROR                 The Debian package mirror to use. See also the --mirror switch above.
                         Defaults to '$MIRROR'
  SECURITY_MIRROR        The Debian package security mirror to use. See also the --security-mirror switch above.
                         Defaults to '$SECURITY_MIRROR'

EOF
    return 0
}

options=$(getopt -o hp:n:a:r:c -l arch:,clean,help,enable-non-free,mirror:,name:,packages:,path:,release:,rootfs:,security-mirror: -- "$@")
if [ $? -ne 0 ]; then
        usage "$(basename "$0")"
        exit 1
fi
eval set -- "$options"

littleendian=$(lscpu | grep '^Byte Order' | grep -q Little && echo yes)

arch=$(uname -m)
if [ "$arch" = "i686" ]; then
    arch="i386"
elif [ "$arch" = "x86_64" ]; then
    arch="amd64"
elif [ "$arch" = "armv7l" ]; then
    arch="armhf"
elif [ "$arch" = "aarch64" ]; then
    arch="arm64"
elif [ "$arch" = "ppc" ]; then
    arch="powerpc"
elif [ "$arch" = "ppc64le" ]; then
    arch="ppc64el"
elif [ "$arch" = "mips" -a "$littleendian" = "yes" ]; then
    arch="mipsel"
elif [ "$arch" = "mips64" -a "$littleendian" = "yes" ]; then
    arch="mips64el"
fi
hostarch=$arch
mainonly=1

while true
do
    case "$1" in
        -h|--help)            usage "$0" && exit 1;;
           --)                shift 1; break ;;

        -a|--arch)            arch=$2; shift 2;;
        -c|--clean)           clean=1; shift 1;;
           --enable-non-free) mainonly=0; shift 1;;
           --mirror)          MIRROR=$2; shift 2;;
        -n|--name)            name=$2; shift 2;;
           --packages)        packages=$2; shift 2;;
        -p|--path)            path=$2; shift 2;;
        -r|--release)         release=$2; shift 2;;
           --rootfs)          rootfs=$2; shift 2;;
           --security-mirror) SECURITY_MIRROR=$2; shift 2;;
        *)                    break ;;
    esac
done

if [ ! -z "$clean" -a -z "$path" ]; then
    clean || exit 1
    exit 0
fi

if [ "$arch" = "i686" ]; then
    arch=i386
fi

if [ "$arch" = "x86_64" ]; then
    arch=amd64
fi

if [ $hostarch = "i386" -a $arch = "amd64" ]; then
    echo "can't create $arch container on $hostarch"
    exit 1
fi

if [ $hostarch = "armhf" -o $hostarch = "armel" ] && \
   [ $arch != "armhf" -a $arch != "armel" ]; then
    echo "can't create $arch container on $hostarch"
    exit 1
fi

if [ $hostarch = "powerpc" -a $arch != "powerpc" ]; then
    echo "can't create $arch container on $hostarch"
    exit 1
fi

type debootstrap
if [ $? -ne 0 ]; then
    echo "'debootstrap' command is missing"
    exit 1
fi

if [ -z "$path" ]; then
    echo "'path' parameter is required"
    exit 1
fi

if [ "$(id -u)" != "0" ]; then
    echo "This script should be run as 'root'"
    exit 1
fi

current_release=$(wget "${MIRROR}/dists/stable/Release" -O - 2> /dev/null | head |awk '/^Codename: (.*)$/ { print $2; }')
release=${release:-${current_release}}
valid_releases=('wheezy' 'jessie' 'stretch' 'buster' 'testing' 'sid' 'unstable')
if [[ ! "${valid_releases[*]}" =~ (^|[^[:alpha:]])$release([^[:alpha:]]|$) ]]; then
    echo "Invalid release ${release}, valid ones are: ${valid_releases[*]}"
    exit 1
fi

# detect rootfs
config="$path/config"
if [ -z "$rootfs" ]; then
    if grep -q '^lxc.rootfs' "$config" 2> /dev/null ; then
        rootfs=$(awk -F= '/^lxc.rootfs[ \t]+=/{ print $2 }' "$config")
    else
        rootfs=$path/rootfs
    fi
fi

# determine the number of ttys - default is 4
if grep -q '^lxc.tty' "$config" 2> /dev/null ; then
    num_tty=$(awk -F= '/^lxc.tty[ \t]+=/{ print $2 }' "$config")
else
    num_tty=4
fi

install_debian "$rootfs" "$release" "$arch" "$LXC_CACHE_PATH"
if [ $? -ne 0 ]; then
    echo "failed to install debian"
    exit 1
fi

configure_debian "$rootfs" "$name" $num_tty
if [ $? -ne 0 ]; then
    echo "failed to configure debian for a container"
    exit 1
fi

copy_configuration "$path" "$rootfs" "$name" $arch $num_tty
if [ $? -ne 0 ]; then
    echo "failed write configuration file"
    exit 1
fi

configure_debian_systemd "$path" "$rootfs" "$config" $num_tty

post_process "${rootfs}" "${release}" "${arch}" "${hostarch}" "${packages}"

if [ ! -z "$clean" ]; then
    clean || exit 1
    exit 0
fi
