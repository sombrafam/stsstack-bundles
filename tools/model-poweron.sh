#!/bin/bash -e
model=$1

(($#)) || { echo "You must provide a model name" && exit 1; }

source ~/novarc
echo "Fetching vms for model '${model}'..."
readarray -t vms<<<"`openstack server list -c ID -c Name -f value| egrep "juju-.+-${model}-[0-9]+"| awk '{print $1}'`"

echo -e "Power on ${#vms[@]} instances for model '${model}'\nContinue? [y/N] "
read answer
[ "${answer,,}" = "y" ] || { echo "aborted"; exit 0; }

echo "Starting ${#vms[@]} vms"
openstack server start ${vms[@]}
echo "Done."