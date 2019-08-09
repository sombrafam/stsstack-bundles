#!/bin/bash -eu
# imports
LIB_COMMON=`dirname $0`/common
. $LIB_COMMON/helpers.sh
f_rel_info=`mktemp`
msgs=()

cleanup () { rm -f $f_rel_info; }
trap cleanup EXIT

# This list provides a way to set "internal opts" i.e. the ones accepted by
# the top-level generate-bundle.sh. The need to modify these should be rare.
declare -a opts=(
--internal-template openstack.yaml.template
--internal-module-path `dirname $0`
)

# Series & Release Info
cat $LIB_COMMON/openstack_release_info.sh > $f_rel_info

# Array list of overlays to use with this deployment.
declare -a overlays=()

# Try to use current model (or newly requested one) as subdomain name
model_subdomain=`get_juju_model`
[ -n "$model_subdomain" ] || model_subdomain="overcloud"

# Bundle template parameters. These should correspond to variables set at the top
# of yaml bundle and overlay templates.
declare -A parameters=()
parameters[__OS_ORIGIN__]=$os_origin
parameters[__SOURCE__]=$source
parameters[__NUM_COMPUTE_UNITS__]=1
parameters[__NUM_CEPH_MON_UNITS__]=1
parameters[__NUM_NEUTRON_GATEWAY_UNITS__]=1
parameters[__NUM_VAULT_UNITS__]=1  # there are > 1 vault* overlay so need to use a global with default
parameters[__NEUTRON_FW_DRIVER__]=openvswitch  # legacy is iptables_hybrid
parameters[__SSL_CA__]=
parameters[__SSL_CERT__]=
parameters[__SSL_KEY__]=
parameters[__DNS_DOMAIN__]="${model_subdomain}.stsstack.qa.1ss."
parameters[__DESIGNATE_NAMESERVERS__]="ns1.${parameters[__DNS_DOMAIN__]}"
parameters[__BIND_DNS_FORWARDER__]='10.198.200.1'
parameters[__ML2_DNS_FORWARDER__]='10.198.200.1'
parameters[__ETCD_SNAP_CHANNEL__]='latest/stable'

# If using any variant of dvr-snat, there is no need for a neutron-gateway.
if ! has_opt --dvr-snat* ${CACHED_STDIN[@]}; then
    overlays+=( "neutron-gateway.yaml" )
fi

trap_help ${CACHED_STDIN[@]:-""}
while (($# > 0))
do
    case "$1" in
        --num-compute)  #__OPT__type:<int>
            parameters[__NUM_COMPUTE_UNITS__]=$2
            shift
            ;;
        --barbican)
            assert_min_release queens "barbican" ${CACHED_STDIN[@]}
            overlays+=( "barbican.yaml" )
            ;;
        --bgp)
            assert_min_release queens "dynamic routing" ${CACHED_STDIN[@]}
            overlays+=( "neutron-bgp.yaml" )
            ;;
        --ceph)
            overlays+=( "ceph.yaml" )
            overlays+=( "openstack-ceph.yaml" )
            ;;
        --num-ceph-mons)  #__OPT__type:<int>
            parameters[__NUM_CEPH_MON_UNITS__]=$2
            shift
            ;;
        --ceph-rgw)
            overlays+=( "ceph.yaml" )
            overlays+=( "ceph-rgw.yaml" )
            ;;
        --ceph-rgw-multisite)
            overlays+=( "ceph.yaml" )
            overlays+=( "ceph-rgw-multisite.yaml" )
            ;;
        --designate)
            assert_min_release ocata "designate" ${CACHED_STDIN[@]}
            ns=${parameters[__BIND_DNS_FORWARDER__]}
            msg="REQUIRED: designate-bind upstream dns server to forward requests to (default=$ns):"
            get_param $1 __BIND_DNS_FORWARDER__ "$msg"
            overlays+=( "neutron-ml2dns.yaml" )
            ns=${parameters[__ML2_DNS_FORWARDER__]}
            msgs+=( "NOTE: you will need to set neutron-gateway dns-servers=<designate-bind unit address> post-deploy (current=$ns)" )
            overlays+=( "memcached.yaml" )
            overlays+=( "designate.yaml" )
            ;;
        --dvr)
            overlays+=( "neutron-dvr.yaml" )
            get_param $1 __DVR_DATA_PORT__ 'REQUIRED: compute host DVR data-port(s) (leave blank to set later): '
            ;;
        --dvr-l3ha*)
            get_param_forced $1 __DVR_DATA_PORT__ 'REQUIRED: compute host DVR data-port(s) (leave blank to set later): '
            get_units $1 __NUM_AGENTS_PER_ROUTER__ 3
            # if we are a dep then don't get gateway units
            if ! `has_opt '--dvr-snat-l3ha' ${CACHED_STDIN[@]}`; then
                get_units $1 __NUM_NEUTRON_GATEWAY_UNITS__ 3
            fi
            overlays+=( "neutron-dvr.yaml" )
            overlays+=( "neutron-l3ha.yaml" )
            ;;
        --dvr-snat-l3ha*)
            assert_min_release queens "dvr-snat-l3ha" ${CACHED_STDIN[@]}
            get_units $1 __NUM_COMPUTE_UNITS__ 3
            get_units $1 __NUM_AGENTS_PER_ROUTER__ 3
            overlays+=( "neutron-dvr-snat.yaml" )
            set -- $@ --dvr-l3ha:${parameters[__NUM_AGENTS_PER_ROUTER__]}
            ;;
        --dvr-snat*)
            assert_min_release queens "dvr-snat" ${CACHED_STDIN[@]}
            get_param_forced $1 __DVR_DATA_PORT__ 'REQUIRED: compute host DVR data-port(s) (leave blank to set later): '
            get_units $1 __NUM_COMPUTE_UNITS__ 1
            overlays+=( "neutron-dvr.yaml" )
            overlays+=( "neutron-dvr-snat.yaml" )
            ;;
        --lma)
            # Logging Monitoring and Alarming
            set -- $@ --graylog --grafana
            ;;
        --graylog)
            overlays+=( "graylog.yaml ")
            msgs+=( "NOTE: you will need to manually relate graylog (filebeat) to any other services you want to monitor" )
            ;;
        --grafana)
            overlays+=( "grafana.yaml ")
            overlays+=( "prometheus-openstack.yaml ")
            if `has_opt '--ceph' ${CACHED_STDIN[@]}`; then
                overlays+=( "prometheus-ceph.yaml ")
            fi
            msgs+=( "NOTE: telegraf has been related to core openstack services but you may need to add to others you have in your deployment" )
            ;;
        --heat)
            overlays+=( "heat.yaml ")
            ;;
        --ldap)
            overlays+=( "ldap.yaml" )
            ;;
        --neutron-fw-driver)  #__OPT__type:[openvswitch|iptables_hybrid] (default=openvswitch)
            assert_min_release newton "openvswitch driver" ${CACHED_STDIN[@]}
            parameters[__NEUTRON_FW_DRIVER__]=$2
            shift
            ;;
        --l3ha*)
            get_units $1 __NUM_NEUTRON_GATEWAY_UNITS__ 3
            get_units $1 __NUM_AGENTS_PER_ROUTER__ 3
            overlays+=( "neutron-l3ha.yaml" )
            ;;
        --keystone-v3)
            # useful for <= pike since queens is v3 only
            overlays+=( "keystone-v3.yaml" )
            ;;
        --keystone-saml)
            assert_min_release rocky "keystone saml" ${CACHED_STDIN[@]}
            overlays+=( "keystone-saml.yaml" )
            ;;
        --mysql-ha*)
            get_units $1 __NUM_MYSQL_UNITS__ 3
            overlays+=( "mysql-ha.yaml" )
            ;;
        --ml2dns)
            # this is internal dns integration, for external use --designate
            ns=${parameters[__ML2_DNS_FORWARDER__]}
            msg="REQUIRED: ml2-dns upstream dns server to forward requests to (default=$ns):"
            get_param $1 __ML2_DNS_FORWARDER__ "$msg"
            overlays+=( "neutron-ml2dns.yaml" )
            ;;
        --nova-cells)
            assert_min_release rocky "nova cells" ${CACHED_STDIN[@]}
            overlays+=( "nova-cells.yaml" )
            ;;
        --octavia)
            # >= Rocky
            assert_min_release rocky "octavia" ${CACHED_STDIN[@]}
            overlays+=( "barbican.yaml" )
            overlays+=( "vault.yaml" )
            overlays+=( "vault-openstack.yaml" )
            overlays+=( "octavia.yaml" )
            ;;
        --rabbitmq-server-ha*)
            get_units $1 __NUM_RABBIT_UNITS__ 3
            overlays+=( "rabbitmq-server-ha.yaml" )
            ;;
        --rsyslog)
            overlays+=( "rsyslog.yaml" )
            ;;
        --ssl)
            if ! `has_opt '--replay' ${CACHED_STDIN[@]}`; then
                (cd ssl; ./create_ca_cert.sh openstack;)
                ssl_results="ssl/openstack/results"
                parameters[__SSL_CA__]=`base64 ${ssl_results}/cacert.pem| tr -d '\n'`
                parameters[__SSL_CERT__]=`base64 ${ssl_results}/servercert.pem| tr -d '\n'`
                parameters[__SSL_KEY__]=`base64 ${ssl_results}/serverkey.pem| tr -d '\n'`
                # Make everything HA with 1 unit (unless --ha has already been set)
                if ! `has_opt '--ha[:0-9]*$' ${CACHED_STDIN[@]}`; then
                    set -- $@ --ha:1
                fi
            fi
            ;;
        --nova-network)
            # NOTE(hopem) yes this is a hack and we'll get rid of it hwen nova-network is finally no more
            opts+=( "--internal-template openstack-nova-network.yaml.template" )
            ;;
        --neutron-sg-logging)
            assert_min_release queens "neutron-sg-logging" ${CACHED_STDIN[@]}
            overlays+=( "neutron-sg-logging.yaml" )            
            ;;
        --cinder-ha*)
            get_units $1 __NUM_CINDER_UNITS__ 3
            overlays+=( "cinder-ha.yaml" )
            ;;
        --designate-ha*)
            get_units $1 __NUM_DESIGNATE_UNITS__ 3
            set -- $@ --designate
            overlays+=( "designate-ha.yaml" )
            ;;
        --glance-ha*)
            get_units $1 __NUM_GLANCE_UNITS__ 3
            overlays+=( "glance-ha.yaml" )
            ;;
        --heat-ha*)
            get_units $1 __NUM_HEAT_UNITS__ 3
            overlays+=( "heat.yaml ")
            overlays+=( "heat-ha.yaml ")
            ;;
        --keystone-ha*)
            get_units $1 __NUM_KEYSTONE_UNITS__ 3
            overlays+=( "keystone-ha.yaml" )
            ;;
        --neutron-api-ha*)
            get_units $1 __NUM_NEUTRON_API_UNITS__ 3
            overlays+=( "neutron-api-ha.yaml" )
            ;;
        --nova-cloud-controller-ha*)
            get_units $1 __NUM_NOVACC_UNITS__ 3
            overlays+=( "nova-cloud-controller-ha.yaml" )
            overlays+=( "memcached.yaml" )
            ;;
        --openstack-dashboard-ha*)
            get_units $1 __NUM_HORIZON_UNITS__ 3
            overlays+=( "openstack-dashboard-ha.yaml" )
            ;;
        --swift)
            overlays+=( "swift.yaml" )
            ;;
        --swift-ha*)
            get_units $1 __NUM_SWIFT_PROXY_UNITS__ 3
            overlays+=( "swift-ha.yaml" )
            ;;
        --telemetry|--telemetry-gnocchi)
            # ceilometer + aodh + gnocchi (>= pike)
            assert_min_release pike "gnocchi" ${CACHED_STDIN[@]} 
            overlays+=( "ceph.yaml" )
            overlays+=( "gnocchi.yaml" )
            overlays+=( "memcached.yaml" )
            overlays+=( "telemetry.yaml" )
            ;;
        --telemetry-legacy-aodh)
            # ceilometer + aodh + mongodb (<= pike)
            overlays+=( "telemetry-legacy-aodh.yaml" )
            ;;
        --telemetry-legacy)
            # ceilometer + mongodb (<= pike)
            overlays+=( "telemetry-legacy.yaml" )
            ;;
        --telemetry-ha*)
            get_units $1 __NUM_TELEMETRY_UNITS__ 3
            overlays+=( "telemetry.yaml" )
            overlays+=( "telemetry-ha.yaml" )
            ;;
        --vault)
            assert_min_release queens "vault" ${CACHED_STDIN[@]}
            overlays+=( "vault.yaml" )
            overlays+=( "vault-openstack.yaml" )
            has_opt '--ceph' ${CACHED_STDIN[@]} && overlays+=( "vault-ceph.yaml" )
            ;;
        --etcd-channel)
            parameters[__ETCD_SNAP_CHANNEL__]=$2
            shift
            ;;
        --vault-ha*)
            get_units $1 __NUM_VAULT_UNITS__ 3
            overlays+=( "vault-ha.yaml" )
            overlays+=( "vault-etcd.yaml" )
            set -- $@ --vault
            ;;
        --ha*)
            get_units $1 __NUM_HA_UNITS__ 3
            units=${parameters[__NUM_HA_UNITS__]}
            # This is HA for "core" service apis only.
            set -- $@ --cinder-ha:$units --glance-ha:$units \
                      --keystone-ha:$units --neutron-api-ha:$units \
                      --nova-cloud-controller-ha:$units
            ;;
        --list-overlays)  #__OPT__
            list_overlays
            exit
            ;;
        *)
            opts+=( $1 )
            ;;
    esac
    shift
done

if ((${#msgs[@]})); then
  for m in "${msgs[@]}"; do
    echo -e "$m"
  done
read -p "Hit [ENTER] to continue"
fi

generate $f_rel_info
