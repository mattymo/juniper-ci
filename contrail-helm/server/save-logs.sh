#!/bin/bash

#TODO:
# my_file="$(readlink -e "$0")"
# my_dir="$(dirname $my_file)"

# source "$my_dir/ssh-defs"

# if $SSH "tar -cvf logs.tar /home/ubuntu/openstack-helm/logs ; gzip logs.tar" ; then
#   $SCP $SSH_DEST:logs.tar.gz "$WORKSPACE/logs/logs.tar.gz"
#   pushd "$WORKSPACE/logs"
#   tar -xvf logs.tar.gz
#   rm logs.tar.gz
#   popd
# fi