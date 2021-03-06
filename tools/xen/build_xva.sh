#!/bin/bash

# This script is run by install_os_domU.sh
#
# It modifies the ubuntu image created by install_os_domU.sh
# and previously moodified by prepare_guest_template.sh
#
# This script is responsible for:
# - pushing in the DevStack code
# - creating run.sh, to run the code on boot
# It does this by mounting the disk image of the VM.
#
# The resultant image is then templated and started
# by install_os_domU.sh

# Exit on errors
set -o errexit
# Echo commands
set -o xtrace

# This directory
TOP_DIR=$(cd $(dirname "$0") && pwd)

# Include onexit commands
. $TOP_DIR/scripts/on_exit.sh

# Source params - override xenrc params in your localrc to suite your taste
source xenrc

#
# Parameters
#
GUEST_NAME="$1"

function _print_interface_config() {
    local device_nr
    local ip_address
    local netmask

    device_nr="$1"
    ip_address="$2"
    netmask="$3"

    local device

    device="eth${device_nr}"

    echo "auto $device"
    if [ $ip_address == "dhcp" ]; then
        echo "iface $device inet dhcp"
    else
        echo "iface $device inet static"
        echo "  address $ip_address"
        echo "  netmask $netmask"
    fi

    # Turn off tx checksumming for better performance
    echo "  post-up ethtool -K $device tx off"
}

function print_interfaces_config() {
    echo "auto lo"
    echo "iface lo inet loopback"

    _print_interface_config $PUB_DEV_NR $PUB_IP $PUB_NETMASK
    _print_interface_config $VM_DEV_NR $VM_IP $VM_NETMASK
    _print_interface_config $MGT_DEV_NR $MGT_IP $MGT_NETMASK
}

#
# Mount the VDI
#
STAGING_DIR=$($TOP_DIR/scripts/manage-vdi open $GUEST_NAME 0 1 | grep -o "/tmp/tmp.[[:alnum:]]*")
add_on_exit "$TOP_DIR/scripts/manage-vdi close $GUEST_NAME 0 1"

# Make sure we have a stage
if [ ! -d $STAGING_DIR/etc ]; then
    echo "Stage is not properly set up!"
    exit 1
fi

# Only support DHCP for now - don't support how different versions of Ubuntu handle resolv.conf
if [ "$MGT_IP" != "dhcp" ] && [ "$PUB_IP" != "dhcp" ]; then
    echo "Configuration without DHCP not supported"
    exit 1
fi

# Copy over devstack
rm -f /tmp/devstack.tar
cd $TOP_DIR/../../
tar --exclude='stage' --exclude='xen/xvas' --exclude='xen/nova' -cvf /tmp/devstack.tar .
mkdir -p $STAGING_DIR/opt/stack/devstack
tar xf /tmp/devstack.tar -C $STAGING_DIR/opt/stack/devstack
cd $TOP_DIR

# Run devstack on launch
cat <<EOF >$STAGING_DIR/etc/rc.local
# network restart required for getting the right gateway
/etc/init.d/networking restart
chown -R $STACK_USER /opt/stack
su -c "/opt/stack/run.sh > /opt/stack/run.sh.log" $STACK_USER
exit 0
EOF

# Configure the hostname
echo $GUEST_NAME > $STAGING_DIR/etc/hostname

# Hostname must resolve for rabbit
HOSTS_FILE_IP=$PUB_IP
if [ $MGT_IP != "dhcp" ]; then
    HOSTS_FILE_IP=$MGT_IP
fi
cat <<EOF >$STAGING_DIR/etc/hosts
$HOSTS_FILE_IP $GUEST_NAME
127.0.0.1 localhost localhost.localdomain
EOF

# Configure the network
print_interfaces_config > $STAGING_DIR/etc/network/interfaces

# Gracefully cp only if source file/dir exists
function cp_it {
    if [ -e $1 ] || [ -d $1 ]; then
        cp -pRL $1 $2
    fi
}

# Copy over your ssh keys and env if desired
COPYENV=${COPYENV:-1}
if [ "$COPYENV" = "1" ]; then
    cp_it ~/.ssh $STAGING_DIR/opt/stack/.ssh
    cp_it ~/.ssh/id_rsa.pub $STAGING_DIR/opt/stack/.ssh/authorized_keys
    cp_it ~/.gitconfig $STAGING_DIR/opt/stack/.gitconfig
    cp_it ~/.vimrc $STAGING_DIR/opt/stack/.vimrc
    cp_it ~/.bashrc $STAGING_DIR/opt/stack/.bashrc
fi

# Configure run.sh
cat <<EOF >$STAGING_DIR/opt/stack/run.sh
#!/bin/bash
cd /opt/stack/devstack
killall screen
VIRT_DRIVER=xenserver FORCE=yes MULTI_HOST=$MULTI_HOST HOST_IP_IFACE=$HOST_IP_IFACE $STACKSH_PARAMS ./stack.sh
EOF
chmod 755 $STAGING_DIR/opt/stack/run.sh
