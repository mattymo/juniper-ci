#!/bin/bash -ex

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

# assume that this file is in home directory of ssh_user
mkdir -p $my_dir/logs

function save_logs() {
  cp -r /var/lib/docker/volumes/kolla_logs/_data $my_dir/logs/ || /bin/true
}

trap 'catch_errors $LINENO' ERR EXIT
function catch_errors() {
  local exit_code=$?
  echo "Line: $1  Error=$exit_code  Command: '$(eval echo $BASH_COMMAND)'"
  trap - ERR EXIT
  set +x
  free -h | tee $my_dir/logs/free.log
  df -h | tee $my_dir/logs/df.log
  ps ax -H > $my_dir/logs/ps_ax.log
  docker ps -a
  save_logs
  exit $exit_code
}

# tune some host settings
sysctl -w vm.max_map_count=1048575

if [[ "$REGISTRY_INSECURE" == '1' ]] ; then
  mkdir -p /etc/docker
  cat <<EOF > /etc/docker/daemon.json
{
    "insecure-registries": ["$CONTRAIL_REGISTRY"]
}
EOF
fi

kolla_path=''
if [[ -x $(command -v apt-get 2>/dev/null) ]]; then
  HOST_OS='ubuntu'
  kolla_path='/usr/local/share'
  sed -i -e "s/{{if1}}/ens3/g" globals.yml
  sed -i -e "s/{{if2}}/ens4/g" globals.yml
elif [[ -x $(command -v yum 2>/dev/null) ]]; then
  HOST_OS='centos'
  kolla_path='/usr/share'
  sed -i -e "s/{{if1}}/eth0/g" globals.yml
  sed -i -e "s/{{if2}}/eth1/g" globals.yml
else
  echo "ERROR: Unable to find apt-get or yum"
  exit 1
fi
sed -i -e "s/{{base_distro}}/$HOST_OS/g" globals.yml
sed -i -e "s/{{openstack_version}}/$OPENSTACK_VERSION/g" globals.yml
sed -i -e "s/{{contrail_version}}/$CONTRAIL_VERSION/g" globals.yml
sed -i -e "s/{{contrail_docker_registry}}/$CONTRAIL_REGISTRY/g" globals.yml
echo 'opencontrail_vrouter_gateway: "192.168.131.1"' >> globals.yml

echo "INFO: Preparing instances"
if [ "x$HOST_OS" == "xubuntu" ]; then
  apt-get install -y --no-install-recommends python-pip
  pip install -U pip setuptools
  apt-get install -y python-dev libffi-dev gcc libssl-dev python-selinux
  pip install -U ansible
elif [ "x$HOST_OS" == "xcentos" ]; then
  # ip is located in /usr/sbin that is not in path...
  export PATH=${PATH}:/usr/sbin

  yum install -y python-pip
  pip install -U pip
  yum install -y python-devel libffi-devel gcc openssl-devel libselinux-python
  yum install -y ansible
fi

# TODO: switch to openstack's repo when work is done
#pip install kolla-ansible
git clone https://github.com/cloudscaling/kolla-ansible
cd kolla-ansible
pip install -r requirements.txt
python setup.py install
cd ..

cp -r $kolla_path/kolla-ansible/etc_examples/kolla /etc/kolla/
cp $kolla_path/kolla-ansible/ansible/inventory/* .
cp globals.yml /etc/kolla

kolla-genpwd
kolla-ansible -i all-in-one bootstrap-servers
kolla-ansible pull -i all-in-one
docker images

mkdir -p /etc/kolla/config/nova
cat <<EOF > /etc/kolla/config/nova/nova-compute.conf
[libvirt]
virt_type = qemu
cpu_mode = none
EOF

kolla-ansible prechecks -i all-in-one

kolla-ansible deploy -i all-in-one
docker ps -a
kolla-ansible post-deploy

set +x

sleep 30
contrail-status

# test it
pip install python-openstackclient
source /etc/kolla/admin-openrc.sh
$kolla_path/kolla-ansible/init-runonce

net_id=`openstack network show demo-net -f value -c id`
openstack server create --image cirros --flavor m1.tiny --key-name mykey --nic net-id=$net_id demo1
sleep 20
openstack server show demo1
# NOTE: assuming that only one VM is running now
if_name=$(ip link | grep -io "tap[0-9a-z-]*")
if [[ -z "$if_name" ]]; then
  echo "ERROR: there is no tap interface for VM"
  ip link
  exit 1
fi
ip=`curl -s http://127.0.0.1:8085/Snh_ItfReq?name=$if_name | sed 's/^.*<mdata_ip_addr.*>\([0-9\.]*\)<.mdata_ip_addr>.*$/\1/'`
if [[ -z "$ip" ]]; then
  echo "ERROR: there is no link-local IP for VM"
  curl -s http://127.0.0.1:8085/Snh_ItfReq?name=$if_name | xmllint --format -
  ip route
  exit 1
fi
ping -c 3 $ip

ssh_opts="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -i ${HOME}/.ssh/id_rsa"
echo "INFO: Wait for instance's ssh is ready"
fail=0
while ! ssh $ssh_opts cirros@$ip whoami ; do
  ((++fail))
  if ((fail > 12)); then
    echo "ERROR: Instance status wait timeout occured"
    exit 1
  fi
  sleep 10
  echo "attempt $fail of 12"
done

# test for outside world
ssh $ssh_opts cirros@$ip ping -q -c 1 -W 2 8.8.8.8
# Check the VM can reach the metadata server
ssh $ssh_opts cirros@$ip curl -s --connect-timeout 5 http://169.254.169.254/latest/meta-data/local-ipv4

trap - ERR EXIT
save_logs
