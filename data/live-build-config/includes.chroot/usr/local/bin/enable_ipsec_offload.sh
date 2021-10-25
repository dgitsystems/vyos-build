#!/usr/bin/env bash

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

# selectively enable on our ConnectX-6 Dx cards (see `lspci -nn` for ids)
devs=$(lspci -Dmmd 15b3:101d | awk '{print$1}')

ipsec_offload_ok=0
ipsec_offload_checked=0

for dev in $devs; do
  devpath="/sys/bus/pci/devices/$dev"
  ifpaths=( "$devpath/net/"* )
  ifnames=( $(printf "%s\n" "${ifpaths[@]}" | awk -F/ '{print$NF}') )
  echo "configuring $dev (${ifnames[@]})"

  devlinks=$(find "$devpath/" -xdev -maxdepth 4 -type d -name devlink)
  if [ ! "$devlinks" ]; then
    log "unable to find devlink under $devpath, skipping $dev" >&2
    exit 1
  fi

  driverpath=$(realpath "$devpath/driver")
  driver=$(basename "$driverpath")
  modulepath=$(realpath "$driverpath/module")

  if [ "$(<$devpath/sriov_numvfs)" = 0 ]; then
    if [ "$driver" = mlx5_core ]; then
      # Skip need to unbind by disabling VF probing before switching to SR-IOV mode
      # echo 0 > /sys/module/mlx5_core/parameters/probe_vf
      set_sys_opt "$modulepath/parameters" probe_vf N
    fi
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
      # if VF interface is not enabled then probe_vf is probably disabled and unbinding is not required
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

    set_sys_opt "$devlink" steering_mode dmfs
    set_sys_opt "$devlink" ipsec_mode full
    set_sys_opt "$devlink" mode switchdev
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
    # - only the PF seems to get devlink so look for that
    # - VFs get the MAC addr_assign_type set to 1 (randomly generated) instead of the PF's 0 (permanent address)
    addr_type=$(<"$ifpath/addr_assign_type")
    if [ "$addr_type" != 0 ] || [ ! -e "$ifpath/compat/devlink" ]; then
      log "not checking ipsec offload state on suspected VF $ifname (addr_assign_type: '$addr_type')"
      continue
    fi

    log "checking ipsec offload on $ifname"
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
