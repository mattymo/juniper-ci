#!/bin/bash -e

my_file="$(readlink -e "$0")"
my_dir="$(dirname $my_file)"

if [[ "$CLEAN_BEFORE" == 'true' || "$CLEAN_BEFORE" == 'clean_and_exit' ]] ; then
  $my_dir/../common/${HOST}/cleanup.sh || /bin/true
  if [[ "$CLEAN_BEFORE" == 'clean_and_exit' ]] ; then
    exit
  fi
fi

rm -rf "$WORKSPACE/logs"
mkdir -p "$WORKSPACE/logs"

# definition for job deployment
source $my_dir/${HOST}-defs

function save_logs() {
  source "$my_dir/../common/${HOST}/ssh-defs"
  set +e
  local ssl_opts=''
  if [[ -n "$SSL_ENABLE" ]] ; then
    ssl_opts="SSL_ENABLE=$SSL_ENABLE"
  fi
  # save common docker logs
  for dest in $nodes_ips ; do
    # TODO: when repo be splitted to containers & build here will be containers repo only,
    # then build repo should be added to be copied below
    timeout -s 9 20s $SCP "$my_dir/../__save-docker-logs.sh" ${SSH_USER}@${dest}:save-docker-logs.sh
    if [[ $? == 0 ]] ; then
      $SSH_CMD ${SSH_USER}@${dest} "CNT_NAME_PATTERN='1-' $ssl_opts ./save-docker-logs.sh"
    fi
  done

  # save env host specific logs
  # (should save into ~/logs folder on the SSH host)
  $my_dir/../common/${HOST}/save-logs.sh

  # save to workspace
  for dest in $nodes_ips ; do
    if timeout -s 9 30s $SSH_CMD ${SSH_USER}@${dest} "sudo tar -cf logs.tar ./logs ; gzip logs.tar" ; then
      local lname=$(echo $dest | cut -d '@' -f 2)
      local ldir="$WORKSPACE/logs/$lname"
      mkdir -p "$ldir"
      timeout -s 9 10s $SCP $SSH_USER@${dest}:logs.tar.gz "$ldir/logs.tar.gz"
      pushd "$ldir"
      tar -xf logs.tar.gz
      rm logs.tar.gz
      popd
    fi
  done
}

$my_dir/../common/${HOST}/create-vm.sh
source "$my_dir/../common/${HOST}/ssh-defs"

trap 'catch_errors $LINENO' ERR
function catch_errors() {
  local exit_code=$?
  echo "Line: $1  Error=$exit_code  Command: '$(eval echo $BASH_COMMAND)'"

  save_logs
  if [[ "$CLEAN_ENV" == 'always' ]] ; then
    $my_dir/../common/${HOST}/cleanup.sh
  fi

  exit $exit_code
}

if [[ "$REGISTRY" == 'build' ]]; then
  $SCP -r "$WORKSPACE/contrail-container-builder" ${SSH_USER}@$build_ip:./
  $SCP "$my_dir/../__build-containers.sh" ${SSH_USER}@$build_ip:build-containers.sh
  set -o pipefail
  ssh_env="CONTRAIL_VERSION=$CONTRAIL_VERSION OPENSTACK_VERSION=$OPENSTACK_VERSION"
  ssh_env+=" CONTRAIL_INSTALL_PACKAGES_URL=$CONTRAIL_INSTALL_PACKAGES_URL"
  $SSH_CMD ${SSH_USER}@$build_ip "$ssh_env timeout -s 9 180m ./build-containers.sh" |& tee $WORKSPACE/logs/build.log
  set +o pipefail
  CONTAINER_REGISTRY="$build_ip:5000"
  CONTRAIL_VERSION="ocata-$CONTRAIL_VERSION"
elif [[ "$REGISTRY" == 'opencontrailnightly' ]]; then
  CONTAINER_REGISTRY='opencontrailnightly'
  CONTRAIL_VERSION='latest'
else
  echo "ERROR: unsupported REGISTRY = $REGISTRY"
  exit 1
fi

# deploy cloud
source "$my_dir/../common/${HOST}/${ENVIRONMENT_OS}"

IP_CONT_01=`echo $nodes_cont_ips | cut -d ' ' -f 1`
IP_COMP_01=`echo $nodes_comp_ips | cut -d ' ' -f 1`
IP_COMP_02=`echo $nodes_comp_ips | cut -d ' ' -f 2`
IP_VIP=${NET_PREFIX}.254
IP_GW=${NET_PREFIX}.1

config=$WORKSPACE/contrail-ansible-deployer/instances.yaml
templ=$(cat $my_dir/instances.yaml.tmpl)
content=$(eval "echo \"$templ\"")
echo "$content" > $config
echo "INFO: cloud config ------------------------- $(date)"
cat $config

image=`docker images -a -q centos-soft`
if [[ -z "$image" ]]; then
  docker pull centos
  docker run -i --name cprep-$JOB_RND --entrypoint /bin/bash centos -c "yum install -y epel-release && yum install -y python-ipaddress git python-pip sudo vim gcc python-devel && pip install pip --upgrade && hash -r && pip install ansible pycrypto oslo_utils oslo_config jinja2"
  docker commit cprep-$JOB_RND centos-soft
  docker rm cprep-$JOB_RND
fi

mkdir -p $WORKSPACE/logs/deployer
volumes="-v $WORKSPACE/contrail-ansible-deployer:/root/contrail-ansible-deployer"
volumes+=" -v $HOME/.ssh:/.ssh"
volumes+=" -v $WORKSPACE/logs/deployer:/root/logs"
volumes+=" -v $my_dir/__run-gate.sh:/root/run-gate.sh"
docker run -i --rm --entrypoint /bin/bash $volumes --network host centos-soft -c "/root/run-gate.sh"

# TODO: wait till cluster up and initialized
sleep 300

# Validate cluster's introspection ports
for dest in $nodes_ips ; do
  $SCP "$my_dir/../__check_introspection.sh" $SSH_USER@${dest}:./check_introspection.sh
done
source "$my_dir/../common/check-functions"
res=0
ips=($nodes_ips)
dest_to_check="${SSH_USER}@${ips[0]}"
for ip in ${ips[@]:1} ; do
  dest_to_check="$dest_to_check,${SSH_USER}@$ip"
done
count=1
limit=3
while ! check_introspection "$dest_to_check" ; do
  echo "INFO: check_introspection ${count}/${limit} failed"
  if (( count == limit )) ; then
    echo "ERROR: Cloud was not up during timeout"
    res=1
    break
  fi
  (( count+=1 ))
  sleep 30
done
test $res == '0'

function aaa() {
ssh root@${ips[0]}
wget -nv https://storage.googleapis.com/kubernetes-helm/helm-v2.9.0-linux-amd64.tar.gz
tar -xvf helm-v2.9.0-linux-amd64.tar.gz
mv linux-amd64/helm /usr/bin/
helm init
kubectl -n kube-system patch deployment tiller-deploy -p '{"spec": {"template": {"spec": {"automountServiceAccountToken": true}}}}'
helm version
kubectl get pods --all-namespaces
helm repo update
# ? helm repo add nfs-provisioner https://raw.githubusercontent.com/IlyaSemenov/nfs-provisioner-chart/master/repo
# ? helm install --name nfs-provisioner --namespace nfs-provisioner nfs-provisioner/nfs-provisioner && sleep 5
# ? kubectl patch storageclass local-nfs -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
helm install --name wordpress --set mariadb.persistence.enabled=false --set persistence.enabled=false stable/wordpress
}

# save logs and exit
trap - ERR
save_logs
if [[ "$CLEAN_ENV" == 'always' || "$CLEAN_ENV" == 'on_success' ]] ; then
  $my_dir/../common/${HOST}/cleanup.sh
fi

exit $res