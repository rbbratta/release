#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

declare vsphere_portgroup
declare vsphere_bastion_portgroup
# shellcheck source=/dev/null
source "${SHARED_DIR}/vsphere_context.sh"
unset SSL_CERT_FILE
unset GOVC_TLS_CA_CERTS

echo "$(date -u --rfc-3339=seconds) vsphere_portgroup: ${vsphere_portgroup}"

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
bastion_name="${CLUSTER_NAME}-bastion"
bastion_ignition_file="${SHARED_DIR}/${CLUSTER_NAME}-bastion.ign"
if [[ ! -f "${bastion_ignition_file}" ]]; then
  echo "'${bastion_ignition_file}' not found, abort." && exit 1
fi
bastion_ignition_base64=$(base64 -w0 <"${bastion_ignition_file}")

if [[ -z "${vsphere_bastion_portgroup:-}" ]]; then
  echo "Not defined vsphere_bastion_portgroup, bastion host will be provisioned in network defined as vsphere_portgroup..."
  vsphere_bastion_portgroup=${vsphere_portgroup}
fi

echo "$(date -u --rfc-3339=seconds) - Configuring govc exports..."
# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"

unset SSL_CERT_FILE
unset GOVC_TLS_CA_CERTS


#Get available ova template
echo "$(date -u --rfc-3339=seconds) - Get avaiable ova template..."
vm_template="${BASTION_OVA_URI##*/}"

if [[ "$(govc vm.info ${vm_template} | wc -c)" -eq 0 ]]; then
  if [[ "$(govc vm.info ${vm_template}-bastion | wc -c)" -eq 0 ]]; then
    echo "${vm_template} and ${vm_template}-bastion does not exist, creating it from ${BASTION_OVA_URI}..."

    cat >/tmp/rhcos.json <<EOF
{
   "DiskProvisioning": "thin",
   "MarkAsTemplate": false,
   "PowerOn": false,
   "InjectOvfEnv": false,
   "WaitForIP": false,
   "Name": "${vm_template}-bastion",
   "NetworkMapping":[{"Name":"VM Network","Network":"${vsphere_bastion_portgroup}"}]
}
EOF

    curl -L -o /tmp/rhcos.ova "${BASTION_OVA_URI}"
    govc import.ova -options=/tmp/rhcos.json /tmp/rhcos.ova &
    wait "$!"
  fi
  vm_template="${vm_template}-bastion"
fi

echo "ova template: ${vm_template}"

#Create bastion host virtual machine
echo "$(date -u --rfc-3339=seconds) - Creating bastion host..."
vm_folder="/${GOVC_DATACENTER}/vm"
govc vm.clone -vm ${vm_folder}/${vm_template} -on=false -net=${vsphere_bastion_portgroup} ${bastion_name}
#govc vm.customize -vm ${vm_folder}/${bastion_name} -name=${bastion_name} -ip=dhcp
govc vm.change -vm ${vm_folder}/vm/${bastion_name} -c "4" -m "8192" -e disk.enableUUID=TRUE
disk_name=$(govc device.info -json -vm ${vm_folder}/${bastion_name} | jq -r '.Devices[]|select(.Type == "VirtualDisk")|.Name')
govc vm.disk.change -vm ${vm_folder}/${bastion_name} -disk.name ${disk_name} -size 100G
govc vm.change -vm ${vm_folder}/${bastion_name} -e "guestinfo.ignition.config.data.encoding=base64"
govc vm.change -vm ${vm_folder}/${bastion_name} -e "guestinfo.ignition.config.data=${bastion_ignition_base64}"
govc vm.power -on ${vm_folder}/${bastion_name}

loop=10
while [ ${loop} -gt 0 ]; do
  # jq -r '.VirtualMachines[0].Guest.Net[] | .IpConfig.IpAddress // [] | select(length > 0) | .[] | select(.IpAddress|test("^fd65")) | .IpAddress + "/" + (.PrefixLength | tostring) '
  # fd65:10:128:3::2/64
  # fd65:a1a8:60ad:271c::1a/128
  # fd65:a1a8:60ad:271c:db6:8144:d9d6:5c4c/64
  bastion_ip=$(govc vm.info -json ${vm_folder}/${bastion_name} | jq -r .VirtualMachines[].Summary.Guest.IpAddress)
  bastion_ipv6=$(govc vm.info -json ${vm_folder}/${bastion_name} | jq -r '.VirtualMachines[0].Guest.Net[] | .IpConfig.IpAddress // [] | select(length > 0) | .[] | select(.IpAddress|test("^fd65")) | .IpAddress' )
  # we require ipv4 and ipv6
  if [[ ${bastion_ip} && ${bastion_ipv6} ]]; then
    break
  else
    loop=$((loop - 1))
    sleep 30
  fi
done

if [[ -z ${bastion_ip} ]]; then
  echo "Unable to get ip of bastion host instance ${bastion_name}!"
  exit 1
fi
if [[ -z ${bastion_ip_v6} ]]; then
  echo "Unable to get ipv6 of bastion host instance ${bastion_name}!"
  exit 1
fi

echo "${vm_folder}/${bastion_name}" >"${SHARED_DIR}/bastion_host_path"
echo "Bastion host created."

#Create dns for bastion host
if [[ "${REGISTER_MIRROR_REGISTRY_DNS}" == "yes" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Creating bastion host DNS..."
  if [[ -f "${SHARED_DIR}"/basedomain.txt ]]; then
    base_domain=$(<"${SHARED_DIR}"/basedomain.txt)
  else
    echo "Unable to find basedomain.txt in SHARED_DIR, set default value..."
    base_domain="vmc-ci.devcluster.openshift.com"
  fi
  export AWS_SHARED_CREDENTIALS_FILE=/var/run/vault/vsphere/.awscred
  export AWS_MAX_ATTEMPTS=50
  export AWS_RETRY_MODE=adaptive

  bastion_host_dns="${bastion_name}.${base_domain}"
  bastion_hosted_zone_id="$(aws route53 list-hosted-zones-by-name \
    --dns-name "${base_domain}" \
    --query "HostedZones[? Config.PrivateZone != \`true\` && Name == \`${base_domain}.\`].Id" \
    --output text)"
  echo "${bastion_hosted_zone_id}" >"${SHARED_DIR}/bastion-hosted-zone.txt"

  # use jq to quote the json
  dns_target=$(jq -n --arg ip "${bastion_ip}" '{TTL: 60, ResourceRecords: [{Value: $ip}]}')
  dns_target_v6=$(jq -n --arg ip "${bastion_ipv6}" '{TTL: 60, ResourceRecords: [{Value: $ip}]}')

  upsert_json=$(jq -n \
    --arg name "${bastion_host_dns}." \
    --arg type "A" \
    --argjson target "${dns_target}" \
    '{Action: "UPSERT", ResourceRecordSet: {Name: $name, Type: $type}} + $target')

  delete_json=$(jq -n \
    --arg name "${bastion_host_dns}." \
    --arg type "A" \
    --argjson target "${dns_target}" \
    '{Action: "DELETE", ResourceRecordSet: {Name: $name, Type: $type}} + $target')

  upsert_json_v6=$(jq -n \
    --arg name "${bastion_host_dns}." \
    --arg type "AAAA" \
    --argjson target "${dns_target_v6}" \
    '{Action: "UPSERT", ResourceRecordSet: {Name: $name, Type: $type}} + $target')

  delete_json_v6=$(jq -n \
    --arg name "${bastion_host_dns}." \
    --arg type "AAAA" \
    --argjson target "${dns_target_v6}" \
    '{Action: "DELETE", ResourceRecordSet: {Name: $name, Type: $type}} + $target')

  # Create JSON files
  jq -n \
    --arg comment "Create public OpenShift DNS records for bastion host on vSphere" \
    --argjson changes "[${upsert_json}, ${upsert_json_v6}]" \
    '{Comment: $comment, Changes: $changes}' > "${SHARED_DIR}/bastion-host-dns-create.json"

  jq -n \
    --arg comment "Delete public OpenShift DNS records for bastion host on vSphere" \
    --argjson changes "[${delete_json}, ${delete_json_v6}]" \
    '{Comment: $comment, Changes: $changes}' > "${SHARED_DIR}/bastion-host-dns-delete.json"

  id=$(aws route53 change-resource-record-sets --hosted-zone-id "$bastion_hosted_zone_id" --change-batch file:///"${SHARED_DIR}"/bastion-host-dns-create.json --query '"ChangeInfo"."Id"' --output text)
  echo "Waiting for DNS records to sync..."
  aws route53 wait resource-record-sets-changed --id "$id"
  echo "DNS records created."

  MIRROR_REGISTRY_URL="${bastion_host_dns}:5000"
  echo "${MIRROR_REGISTRY_URL}" >"${SHARED_DIR}/mirror_registry_url"
fi

echo "bastion ip address: ${bastion_ip}"
echo "bastion ipv6 address: ${bastion_ipv6}"

#Save bastion information
echo "${bastion_ip}" >"${SHARED_DIR}/bastion_private_address"
echo "${bastion_ipv6}" >"${SHARED_DIR}/bastion_private_ipv6_address"
echo "core" >"${SHARED_DIR}/bastion_ssh_user"

proxy_credential=$(cat /var/run/vault/proxy/proxy_creds)
proxy_private_url="http://${proxy_credential}@${bastion_ip}:3128"
echo "${proxy_private_url}" >"${SHARED_DIR}/proxy_private_url"
proxy_private_url_v6="http://${proxy_credential}@[${bastion_ipv6}]:3128"
echo "${proxy_private_url_v6}" >"${SHARED_DIR}/proxy_private_url_v6"

# echo proxy IP to ${SHARED_DIR}/proxyip
echo "${bastion_ip}" >"${SHARED_DIR}/proxyip"
echo "${bastion_ipv6}" >"${SHARED_DIR}/proxyipv6"

echo "Sleeping 5 mins, make sure that the bastion host is fully started."
sleep 300
