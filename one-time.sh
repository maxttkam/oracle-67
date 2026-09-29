#!/usr/bin/env bash
# Create OCI reserved public IPs until one matches the regex, then stop and keep it.
# Non-matching IPs are deleted right away.
#
# Usage:
#   export OCI_COMPARTMENT_ID=ocid1.compartment.oc1..xxxx
#   ./one-time.sh
#
# Options (env vars):
#   MATCH_MODE='\.67\.'  extended regex tested against the IP (default: 67 as a middle octet)
#   SLEEP=1              seconds between attempts
#   MAX_TRIES=0          stop after N IPs, 0 = unlimited

set -uo pipefail

COMPARTMENT_ID="${OCI_COMPARTMENT_ID:-${1:-}}"
MATCH_MODE="${MATCH_MODE:-\\.67\\.}"
SLEEP="${SLEEP:-1}"
MAX_TRIES="${MAX_TRIES:-0}"

[[ -z "$COMPARTMENT_ID" ]] && { echo "Set OCI_COMPARTMENT_ID or pass the compartment OCID as the first argument." >&2; exit 1; }
command -v oci >/dev/null 2>&1 || { echo "oci CLI not found in PATH." >&2; exit 1; }

delete_ip() { oci network public-ip delete --public-ip-id "$1" --force >/dev/null 2>&1; }

current_id=""
trap 'echo; [[ -n "$current_id" ]] && { echo "Interrupted, deleting $current_id ..."; delete_ip "$current_id"; }; exit 130' INT TERM

echo "Match regex: $MATCH_MODE"
n=0
backoff=10

while :; do
  (( MAX_TRIES > 0 && n >= MAX_TRIES )) && { echo "Reached MAX_TRIES ($MAX_TRIES) with no match."; exit 2; }

  # Output is "<ocid> <ip-address>"
  out=$(oci network public-ip create \
          --compartment-id "$COMPARTMENT_ID" \
          --lifetime RESERVED \
          --display-name "ip-hunt-$((n + 1))" \
          --query "join(' ', [data.id, data.\"ip-address\"])" \
          --raw-output 2>&1)
  rc=$?

  if (( rc != 0 )); then
    echo "[$((n + 1))] create failed (retrying in ${backoff}s): $(echo "$out" | tr '\n' ' ' | cut -c1-200)"
    sleep "$backoff"
    backoff=$(( backoff < 120 ? backoff * 2 : 120 ))
    continue
  fi
  backoff=10

  n=$((n + 1))
  read -r id ip <<< "$out"
  current_id="$id"

  if [[ "$ip" =~ $MATCH_MODE ]]; then
    echo "[$n] $ip  <-- match! Keeping it."
    echo "Name: ip-hunt-$n"
    echo "OCID: $id"
    current_id=""
    exit 0
  fi

  echo "[$n] $ip  no match, deleting"
  delete_ip "$id" || echo "Warning: failed to delete $id, check it manually." >&2
  current_id=""

  sleep "$SLEEP"
done
