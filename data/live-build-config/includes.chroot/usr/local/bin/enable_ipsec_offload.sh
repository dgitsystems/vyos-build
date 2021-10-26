#!/usr/bin/env bash

# This script will enable SR-IOV, set full IPSec offload and then change to switchdev e-switch mode

set -euo pipefail

trap 'log error $? on line $LINENO' ERR

log() {
  if [ "$dev" ]; then
    echo "[$dev]:" "$@"
  else
    echo "$@"
  fi
}

set_sys_opt() {
  local path=$1
  local opt=$2
  local value=$3

  log "set $opt to $value in $path/$opt"
  if [ ! -f "$path/$opt" ]; then
    log "$path/$opt does not exist, unable to proceed" >&2
    return 1
  fi

  local curvalue
  curvalue=$(<"$path/$opt")
  if [ "$curvalue" = "$value" ]; then
    log "$opt already set to $curvalue"
    return 0
  fi

  echo "$value" > "$path/$opt"
}

set_devlink_param() {
  local devlink=$1
  local param=$2
  local value=$3

  log "set $param to $value on $devlink"
  local jsonvalue
  if ! jsonvalue=$(devlink dev param show "$devlink" name "$param" -j); then
    log "unable to get $param value, unable to proceed" >&2
    return 1
  fi

  local curvalue
  if ! curvalue=$(<<<"$jsonvalue" python3 -c "import json,sys;print(json.load(sys.stdin)['param']['$devlink'][0]['values'][0]['value'])") || [ ! "$curvalue" ]; then
    log "unable to parse current value from devlink JSON: $jsonvalue" >&2
    return 1
  fi

  if [ "$curvalue" = "$value" ]; then
    log "$param already set to $curvalue"
    return 0
  fi

  devlink dev param set "$devlink" name "$param" value "$value" cmode runtime
}

# selectively enable on our ConnectX-6 Dx cards (see `lspci -nn` for ids)
devs=$(lspci -Dmmd 15b3:101d | awk '{print$1}')

ipsec_offload_ok=0
ipsec_offload_checked=0

for dev in $devs; do
  devpath="/sys/bus/pci/devices/$dev"
  ifpaths=( "$devpath/net/"* )
  ifnames=( $(printf "%s\n" "${ifpaths[@]}" | awk -F/ '{print$NF}') )
  echo "configuring $dev (${ifnames[@]})"

  devlinks=$(devlink dev show "pci/$dev")
  if [ ! "$devlinks" ]; then
    log "unable to find devlink under $devpath, skipping $dev" >&2
    exit 1
  fi

  driverpath=$(realpath "$devpath/driver")
  driver=$(basename "$driverpath")
  modulepath=$(realpath "$driverpath/module")

  if [ "$(<$devpath/sriov_numvfs)" = 0 ]; then
    # Skip need to unbind by disabling VF probing before switching to SR-IOV mode
    set_sys_opt "$devpath" sriov_drivers_autoprobe 0

    set_sys_opt "$devpath" sriov_numvfs 1
  fi

  rebindvfs=()
  vfs=$(realpath "$devpath/virtfn"*)
  for vf in $vfs; do
    if [ ! -e "$vf" ]; then
      log "no VFs found" >&2
      continue
    fi

    if [ -e "$vf/enable" ] && [ "$(<"$vf/enable")" = 0 ]; then
      # if VF interface is not enabled then sriov_drivers_autoprobe/probe_vf is probably disabled and unbinding is not required
      continue
    fi
    vfaddr=$(basename "$vf")
    log "unbind VF $vfaddr"
    echo "$vfaddr" > "$driverpath/unbind"
    rebindvfs+=( "$vf" )
  done

  for devlink in $devlinks; do
# if it was already in switchdev mode then you need to switch back to legacy first
#    set_sys_opt "$devlink" mode legacy
#    set_sys_opt "$devlink" ipsec_mode none

    set_devlink_param "$devlink" flow_steering_mode dmfs

    # note: ipsec_mode is not (at least currently) a parameter that can be set via devlink (see `devlink dev param -jp`), so this depends on the compat/devlink interface provided by MLNX_EN
    set_sys_opt "/sys/bus/pci/devices/$dev/net/"*"/compat/devlink" ipsec_mode full

    # devlink dev eswitch show "$devlink" -j | python3 -c "import json,sys;print(json.load(sys.stdin)['dev']['$devlink']['mode'])"
    devlink dev eswitch set "$devlink" mode switchdev
  done

  # if we unbinded the VF then bind it again now
  for vf in "${rebindvfs[@]}"; do
    vfaddr=$(basename "$vf")
    log "bind VF $vfaddr"
    echo "$vfaddr" > "$driverpath/bind"
  done

  # validate offload mode
  ipsec_offload_ok_prev=$ipsec_offload_ok
  for ifpath in "${ifpaths[@]}"; do
    ifname=$(basename "$ifpath")

    # only check PF, ignore the VF interfaces
    porttype=$(devlink port show "$ifname" -jp | python3 -c "import json,sys;json = json.load(sys.stdin)['port']; key = list(json.keys())[0]; print(json[key]['flavour'])")
    if [ "$porttype" != physical ]; then
      log "not checking ipsec offload state on $ifname ($porttype)"
      continue
    fi

    log "checking ipsec offload on $ifname ($porttype)"
    let ipsec_offload_checked+=1

    if ethtool -S "$ifname" | awk -v DEV="$dev" '/^\s*ipsec_full_/{MATCHES++;print"["DEV"]: "$0}END{if(MATCHES!=8){exit 1}}'; then
      let ipsec_offload_ok+=1
    else
      log "ipsec offload does not appear to have activated on $ifname" >&2
    fi
  done
  if [ "$ipsec_offload_ok_prev" = "$ipsec_offload_ok" ]; then
    let ipsec_offload_checked+=1
    log "ERROR: ipsec offload mode was not validated for any interface" >&2
  fi
done

if [ "$ipsec_offload_ok" != "$ipsec_offload_checked" ]; then
  echo "error: ipsec offload active on $ipsec_offload_ok/$ipsec_offload_checked interfaces" >&2
  exit 1
elif [ "$ipsec_offload_ok" -lt 1 ]; then
  echo "error: ipsec offload inactive" >&2
  exit 2
fi

echo "ipsec offload active on $ipsec_offload_ok interfaces"
