#!/bin/bash -ex

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

ssh_key_dir="/home/jenkins"

export ENVIRONMENT_OS=${1:-${ENVIRONMENT_OS:-''}}
export OPENSTACK_VERSION=${2:-${OPENSTACK_VERSION:-''}}

export VM_NAME=${VM_NAME:-"oshelm-${ENVIRONMENT_OS}-${OPENSTACK_VERSION}"}
export DISK_SIZE=${DISK_SIZE:-'128'}
export POOL_NAME=${POOL_NAME:-'oshelm'}
export VOL_NAME=${VOL_NAME:-"${VM_NAME}.qcow2"}
export NET_DRIVER=${NET_DRIVER:-'e1000'}
export BRIDGE_NAME=${BRIDGE_NAME:-'oshelm'}

if [[ -z "$ENVIRONMENT_OS" ]] ; then
  echo "ENVIRONMENT_OS is expected (e.g. export ENVIRONMENT_OS=centos)"
  exit 1
fi

if [[ -z "$OPENSTACK_VERSION" ]] ; then
  echo "OPENSTACK_VERSION is expected (e.g. export OPENSTACK_VERSION=ocata)"
  exit 1
fi

if [[ "$ENVIRONMENT_OS" == 'rhel' ]] ; then
  if [[ -z "$RHEL_ACCOUNT_FILE" ]] ; then
    echo "ERROR: for rhel environemnt the environment variable RHEL_ACCOUNT_FILE is required"
    exit 1
  fi
fi

# base image for VMs
if [[ "$ENVIRONMENT_OS" == 'rhel' ]] ; then
  DEFAULT_BASE_IMAGE_NAME="oshelm-${ENVIRONMENT_OS}-${ENVIRONMENT_OS_VERSION}-${OPENSTACK_VERSION}.qcow2"
else
  DEFAULT_BASE_IMAGE_NAME="oshelm-${ENVIRONMENT_OS}-${OPENSTACK_VERSION}.qcow2"
fi
BASE_IMAGE_NAME=${BASE_IMAGE_NAME:-"$DEFAULT_BASE_IMAGE_NAME"}
BASE_IMAGE_POOL=${BASE_IMAGE_POOL:-'images'}
BASE_IMAGE_DIR=${BASE_IMAGE_DIR:-'/home/root/images'}
BASE_IMAGE="${BASE_IMAGE_DIR}/${BASE_IMAGE_NAME}"

if [[ ! -f ${BASE_IMAGE} ]] ; then
  echo "There is no image file ${BASE_IMAGE}"
  exit 1
fi

source "$my_dir/../../common/virsh/functions"

assert_env_exists "$VM_NAME"

# re-create network
net_name="${VM_NAME}"
delete_network_dhcp $net_name
if [[ "$ENVIRONMENT_OS" == 'rhel' ]]; then
  net_addr="192.168.221.0"
else
  net_addr="192.168.222.0"
fi
create_network_dhcp $net_name $net_addr $BRIDGE_NAME

# create pool
create_pool $POOL_NAME

# re-create disk
delete_volume $VOL_NAME $POOL_NAME
vol_path=$(create_volume_from $VOL_NAME $POOL_NAME $BASE_IMAGE_NAME $BASE_IMAGE_POOL)

VCPUS=8
MEM=38528
OS_VARIANT='rhel7'
if [[ "$ENVIRONMENT_OS" == 'ubuntu' ]] ; then
  OS_VARIANT='ubuntu'
fi
define_machine $VM_NAME $VCPUS $MEM $OS_VARIANT $net_name $vol_path $DISK_SIZE

# customize domain to set root password
# TODO: access denied under non root...
# customized manually for now
# domain_customize $VM_NAME

# start machine
start_vm $VM_NAME

#TODO: wait machine and get IP via virsh net-dhcp-leases $net_name