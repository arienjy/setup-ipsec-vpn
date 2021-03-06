#!/bin/sh
#
# Script to upgrade Libreswan on CentOS and RHEL
#
# Copyright (C) 2016-2020 Lin Song <linsongui@gmail.com>
#
# This work is licensed under the Creative Commons Attribution-ShareAlike 3.0
# Unported License: http://creativecommons.org/licenses/by-sa/3.0/
#
# Attribution required: please include my name in any derivative and let me
# know how you have improved it!

# Specify which Libreswan version to install. See: https://libreswan.org
SWAN_VER=4.1

### DO NOT edit below this line ###

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

exiterr()  { echo "Error: $1" >&2; exit 1; }
exiterr2() { exiterr "'yum install' failed."; }

vpnupgrade() {

if ! grep -qs -e "release 6" -e "release 7" -e "release 8" /etc/redhat-release; then
  echo "Error: This script only supports CentOS/RHEL 6, 7 and 8." >&2
  echo "For Ubuntu/Debian, use https://git.io/vpnupgrade" >&2
  exit 1
fi

if [ -f /proc/user_beancounters ]; then
  exiterr "OpenVZ VPS is not supported."
fi

if [ "$(id -u)" != 0 ]; then
  exiterr "Script must be run as root. Try 'sudo sh $0'"
fi

case "$SWAN_VER" in
  3.2[679]|3.3[12]|4.1)
    /bin/true
    ;;
  *)
cat 1>&2 <<EOF
Error: Libreswan version '$SWAN_VER' is not supported.
  This script can install one of the following versions:
  3.26-3.27, 3.29, 3.31-3.32 or 4.1
EOF
    exit 1
    ;;
esac

dns_state=0
DNS_SRV1=$(grep "modecfgdns1=" /etc/ipsec.conf | head -n 1 | cut -d '=' -f 2)
DNS_SRV2=$(grep "modecfgdns2=" /etc/ipsec.conf | head -n 1 | cut -d '=' -f 2)
[ -n "$DNS_SRV1" ] && dns_state=2
[ -n "$DNS_SRV1" ] && [ -n "$DNS_SRV2" ] && dns_state=1
[ "$(grep -c "modecfgdns1=" /etc/ipsec.conf)" -gt "1" ] && dns_state=3

ipsec_ver=$(/usr/local/sbin/ipsec --version 2>/dev/null)
ipsec_ver_short=$(printf '%s' "$ipsec_ver" | sed -e 's/Linux Libreswan/Libreswan/' -e 's/ (netkey) on .*//')
swan_ver_old=$(printf '%s' "$ipsec_ver_short" | sed -e 's/Libreswan //')
if ! printf '%s' "$ipsec_ver" | grep -q "Libreswan"; then
  exiterr "This script requires Libreswan already installed."
fi

if [ "$swan_ver_old" = "$SWAN_VER" ]; then
  echo "You already have Libreswan version $SWAN_VER installed! "
  echo "If you continue, the same version will be re-installed."
  echo
  printf "Do you want to continue anyway? [y/N] "
  read -r response
  case $response in
    [yY][eE][sS]|[yY])
      echo
      ;;
    *)
      echo "Abort. No changes were made."
      exit 1
      ;;
  esac
fi

clear

cat <<EOF
Welcome! This script will build and install Libreswan on your server.
Additional packages required for compilation will also be installed.

It is intended for upgrading servers to a newer Libreswan version.

Current version:    $ipsec_ver_short
Version to install: Libreswan $SWAN_VER

EOF

cat <<'EOF'
NOTE: This script will make the following changes to your IPsec config:

    - Fix obsolete ipsec.conf and/or ikev2.conf options
    - Optimize VPN ciphers

    Your other VPN configuration files will not be modified.

EOF

case "$SWAN_VER" in
  3.2[679]|3.3[12])
cat <<'EOF'
WARNING: Older versions of Libreswan could contain known security vulnerabilities.
    See https://libreswan.org/security/ for more information.
    Are you sure you want to install an older version?

EOF
    ;;
esac

printf "Do you want to continue? [y/N] "
read -r response
case $response in
  [yY][eE][sS]|[yY])
    echo
    echo "Please be patient. Setup is continuing..."
    echo
    ;;
  *)
    echo "Abort. No changes were made."
    exit 1
    ;;
esac

# Create and change to working dir
mkdir -p /opt/src
cd /opt/src || exit 1

# Add the EPEL repository
epel_url="https://dl.fedoraproject.org/pub/epel/epel-release-latest-$(rpm -E '%{rhel}').noarch.rpm"
yum -y install epel-release || yum -y install "$epel_url" || exiterr2

# Install necessary packages
yum -y install nss-devel nspr-devel pkgconfig pam-devel \
  libcap-ng-devel libselinux-devel curl-devel nss-tools \
  flex bison gcc make wget sed tar || exiterr2

REPO1='--enablerepo=*server-*optional*'
REPO2='--enablerepo=*releases-optional*'
REPO3='--enablerepo=PowerTools'

if grep -qs "release 6" /etc/redhat-release; then
  yum -y remove libevent-devel
  yum "$REPO1" "$REPO2" -y install libevent2-devel fipscheck-devel || exiterr2
elif grep -qs "release 7" /etc/redhat-release; then
  yum -y install systemd-devel || exiterr2
  yum "$REPO1" "$REPO2" -y install libevent-devel fipscheck-devel || exiterr2
else
  if grep -qs "Red Hat" /etc/redhat-release; then
    REPO3='--enablerepo=codeready-builder-for-rhel-8-*'
  fi
  yum "$REPO3" -y install systemd-devel libevent-devel fipscheck-devel || exiterr2
fi

# Compile and install Libreswan
swan_file="libreswan-$SWAN_VER.tar.gz"
swan_url1="https://github.com/libreswan/libreswan/archive/v$SWAN_VER.tar.gz"
swan_url2="https://download.libreswan.org/$swan_file"
if ! { wget -t 3 -T 30 -nv -O "$swan_file" "$swan_url1" || wget -t 3 -T 30 -nv -O "$swan_file" "$swan_url2"; }; then
  exit 1
fi
/bin/rm -rf "/opt/src/libreswan-$SWAN_VER"
tar xzf "$swan_file" && /bin/rm -f "$swan_file"
cd "libreswan-$SWAN_VER" || exit 1
[ "$SWAN_VER" = "3.26" ] && sed -i 's/-lfreebl //' mk/config.mk
[ "$SWAN_VER" = "3.26" ] && sed -i '/blapi\.h/d' programs/pluto/keys.c
if [ "$SWAN_VER" = "3.31" ]; then
  sed -i '916iif (!st->st_seen_fragvid) { return FALSE; }' programs/pluto/ikev2.c
  sed -i '1033s/if (/if (LIN(POLICY_IKE_FRAG_ALLOW, sk->ike->sa.st_connection->policy) \&\& sk->ike->sa.st_seen_fragvid \&\& /' \
    programs/pluto/ikev2_message.c
fi
[ "$SWAN_VER" = "4.1" ] && sed -i 's/ sysv )/ sysvinit )/' programs/setup/setup.in
cat > Makefile.inc.local <<'EOF'
WERROR_CFLAGS=-w
USE_DNSSEC=false
USE_DH31=false
USE_NSS_AVA_COPY=true
USE_NSS_IPSEC_PROFILE=false
USE_GLIBC_KERN_FLIP_HEADERS=true
EOF
if [ "$SWAN_VER" = "3.31" ] || [ "$SWAN_VER" = "3.32" ] || [ "$SWAN_VER" = "4.1" ]; then
  echo "USE_DH2=true" >> Makefile.inc.local
  if ! grep -qs IFLA_XFRM_LINK /usr/include/linux/if_link.h; then
    echo "USE_XFRM_INTERFACE_IFLA_HEADER=true" >> Makefile.inc.local
  fi
fi
if [ "$SWAN_VER" = "4.1" ]; then
  echo "USE_NSS_KDF=false" >> Makefile.inc.local
  echo "FINALNSSDIR=/etc/ipsec.d" >> Makefile.inc.local
fi
NPROCS=$(grep -c ^processor /proc/cpuinfo)
[ -z "$NPROCS" ] && NPROCS=1
make "-j$((NPROCS+1))" -s base && make -s install-base

# Verify the install and clean up
cd /opt/src || exit 1
/bin/rm -rf "/opt/src/libreswan-$SWAN_VER"
if ! /usr/local/sbin/ipsec --version 2>/dev/null | grep -qF "$SWAN_VER"; then
  exiterr "Libreswan $SWAN_VER failed to build."
fi

# Restore SELinux contexts
restorecon /etc/ipsec.d/*db 2>/dev/null
restorecon /usr/local/sbin -Rv 2>/dev/null
restorecon /usr/local/libexec/ipsec -Rv 2>/dev/null

# Update IPsec config
IKE_NEW="  ike=aes256-sha2,aes128-sha2,aes256-sha1,aes128-sha1,aes256-sha2;modp1024,aes128-sha1;modp1024"
PHASE2_NEW="  phase2alg=aes_gcm-null,aes128-sha1,aes256-sha1,aes256-sha2_512,aes128-sha2,aes256-sha2"

sed -i".old-$(date +%F-%T)" \
    -e "s/^[[:space:]]\+auth=/  phase2=/" \
    -e "s/^[[:space:]]\+forceencaps=/  encapsulation=/" \
    -e "s/^[[:space:]]\+ike-frag=/  fragmentation=/" \
    -e "s/^[[:space:]]\+sha2_truncbug=/  sha2-truncbug=/" \
    -e "s/^[[:space:]]\+sha2-truncbug=yes/  sha2-truncbug=no/" \
    -e "s/^[[:space:]]\+ike=.\+/$IKE_NEW/" \
    -e "s/^[[:space:]]\+phase2alg=.\+/$PHASE2_NEW/" /etc/ipsec.conf

if [ "$dns_state" = "1" ]; then
  sed -i -e "s/^[[:space:]]\+modecfgdns1=.\+/  modecfgdns=\"$DNS_SRV1 $DNS_SRV2\"/" \
      -e "/modecfgdns2=/d" /etc/ipsec.conf
elif [ "$dns_state" = "2" ]; then
  sed -i "s/^[[:space:]]\+modecfgdns1=.\+/  modecfgdns=$DNS_SRV1/" /etc/ipsec.conf
fi

case "$SWAN_VER" in
  3.29|3.3[12]|4.1)
    sed -i "/ikev2=never/d" /etc/ipsec.conf
    sed -i "/conn shared/a \  ikev2=never" /etc/ipsec.conf
    ;;
esac

if grep -qs ike-frag /etc/ipsec.d/ikev2.conf; then
  sed -i 's/^[[:space:]]\+ike-frag=/  fragmentation=/' /etc/ipsec.d/ikev2.conf
fi

# Restart IPsec service
mkdir -p /run/pluto
service ipsec restart

cat <<EOF


===========================================

Libreswan $SWAN_VER successfully installed!

===========================================

EOF

if [ "$dns_state" = "3" ]; then
cat <<'EOF'
IMPORTANT: Users upgrading to Libreswan 3.23 or newer must edit /etc/ipsec.conf
    and replace all occurrences of these two lines:

      modecfgdns1=DNS_SERVER_1
      modecfgdns2=DNS_SERVER_2

    with a single line like this:

      modecfgdns="DNS_SERVER_1 DNS_SERVER_2"

    Then run "sudo service ipsec restart".

EOF
fi

}

## Defer setup until we have the complete script
vpnupgrade "$@"

exit 0
