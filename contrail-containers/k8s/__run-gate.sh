#!/bin/bash -ex

function log_info() {
  echo "INFO: $@"
}

function log_error() {
  echo "ERROR: $@"
}

pushd contrail-container-builder/kubernetes/manifests/
./resolve-manifest.sh <contrail-template.yaml > ~/my-contrail.yaml
popd

function wait_cluster() {
  local name=$1
  local pods_rgx=$2
  log_info "Wait $name up.."
  local total=0
  local running=0
  local i=0
  for (( i=0 ; i < 600 ; ++i )) ; do
    (( total=1 + $(kubectl get pods --all-namespaces=true | grep -c "$pods_rgx") ))
     (( running=1 + $(kubectl get pods --all-namespaces=true | grep "$pods_rgx" | grep -ic 'running') ))
    log_info "  components up: ${running}/${total}"
    if (( total != 1 && total == running )) ; then
      log_info "$name is running"
      break
    fi
  done
  if (( total != running )) ; then
    log_error "$name failed to run till timeout"
    exit -1
  fi
}

log_info "create Contrail cluster"
kubectl create -f ~/my-contrail.yaml
wait_cluster "Contrail" "contrail\|zookeeper\|rabbit\|kafka\|redis"

log_info "Run test application: nginx"
cat <<EOF > ~/test_app.yaml
apiVersion: apps/v1beta1 # for versions before 1.8.0 use apps/v1beta1
kind: Deployment
metadata:
  name: nginx-deployment
spec:
  selector:
    matchLabels:
      app: nginx
  replicas: 1 # tells deployment to run 2 pods matching the template
  template: # create pods using pod definition in this template
    metadata:
      # unlike pod-nginx.yaml, the name is not included in the meta data as a unique name is
      # generated from the deployment name
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:1.7.9
        ports:
        - containerPort: 80
      tolerations:
      - operator: "Exists"
        effect: "NoSchedule"
EOF

log_info "run test application"
kubectl create -f ~/test_app.yaml
wait_cluster "nginx" "nginx"

# TODO: test connectivities