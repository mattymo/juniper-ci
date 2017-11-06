#!/bin/bash -ex

if [[ "$USE_SWAP" == "true" ]] ; then
  sudo mkswap /dev/xvdf
  sudo swapon /dev/xvdf
  swapon -s
fi

if [[ -x $(command -v apt-get 2>/dev/null) ]]; then
  HOST_OS='ubuntu'
elif [[ -x $(command -v yum 2>/dev/null) ]]; then
  HOST_OS='centos'
else
  echo "ERROR: Unable to find apt-get or yum"
  exit 1
fi

echo "INFO: Preparing instances"
if [ "x$HOST_OS" == "xubuntu" ]; then
  sudo apt-get -y update && sudo apt-get -y upgrade
  sudo apt-get install -y --no-install-recommends mc git wget ntp
elif [ "x$HOST_OS" == "xcentos" ]; then
  sudo yum install -y epel-release
  sudo cp ./ceph.repo /etc/yum.repos.d/ceph.repo
  sudo yum install -y mc git wget ntp
fi

git clone ${OPENSTACK_HELM_URL:-https://github.com/openstack/openstack-helm}
cd openstack-helm

# fetch latest
if [[ -n "$CHANGE_REF" ]] ; then
  echo "INFO: Checking out change ref $CHANGE_REF"
  git fetch https://git.openstack.org/openstack/openstack-helm "$CHANGE_REF" && git checkout FETCH_HEAD
fi

# TODO: define the IP in chart
iface=`ip -4 route list 0/0 | awk '{ print $5; exit }'`
local_ip=`ip addr | grep $iface | grep 'inet ' | awk '{print $2}' | cut -d '/' -f 1`
sudo cp -f /etc/hosts /etc/hosts.bak
sudo sed -i "/$(hostname)/d" /etc/hosts
echo "$local_ip $(hostname)" | sudo tee -a /etc/hosts
for fn in `grep -r -l 10.0.2.15 *`; do sed "s/10.0.2.15/$local_ip/g" < "$fn" > result; rm "$fn"; mv result "$fn"; done

export INTEGRATION=aio
export INTEGRATION_TYPE=basic
export SDN_PLUGIN=opencontrail
#export GLANCE=pvc
#export PVC_BACKEND=ceph
./tools/gate/setup_gate.sh
