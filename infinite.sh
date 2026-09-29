#!/usr/bin/env bash
# Keep creating OCI reserved public IPs forever.
#   - IPs that match are KEPT (and remembered), non-matching IPs are deleted right away.
#   - Press  i  at any time to print a summary of everything matched so far.
#   - Press Ctrl-C to quit (a summary is printed on the way out).
#
# Usage:
#   export OCI_COMPARTMENT_ID=ocid1.compartment.oc1..xxxx
#   ./infinite.sh
#
# Options (env vars):
#   MATCH_MODE='(^|\.)67(\.|$)'  extended regex tested against the IP string (default).
#                                Matches only when a whole octet is exactly 67:
#                                100.67.0.0 and 199.1.67.66 match, 199.167.5.43 does not.
#   SLEEP=1                      seconds to wait between attempts (default 1, minimum 1)
#   MAX_TRIES=0                  stop after N IPs checked, 0 = unlimited (default 0)

set -uo pipefail

COMPARTMENT_ID="${OCI_COMPARTMENT_ID:-${1:-}}"
MATCH_MODE="${MATCH_MODE:-(^|\\.)67(\\.|\$)}"
SLEEP="${SLEEP:-1}"
MAX_TRIES="${MAX_TRIES:-0}"
(( SLEEP < 1 )) && SLEEP=1

if [[ -z "$COMPARTMENT_ID" ]]; then
  echo "Set OCI_COMPARTMENT_ID or pass the compartment OCID as the first argument." >&2
  exit 1
fi

command -v oci >/dev/null 2>&1 || { echo "oci CLI not found in PATH." >&2; exit 1; }

checked=0            # IPs successfully created and checked
current_id=""        # OCID of the IP currently being evaluated (for Ctrl-C cleanup)
matched_ips=()
matched_names=()
matched_ids=()

# --- keyboard handling -------------------------------------------------------
HAVE_TTY=0
SAVED_STTY=""
if [[ -t 0 ]]; then
  HAVE_TTY=1
  SAVED_STTY=$(stty -g)
  stty -echo -icanon      # read single keypresses, don't echo them (Ctrl-C still works)
fi

restore_tty() {
  if [[ -n "$SAVED_STTY" ]]; then stty "$SAVED_STTY" 2>/dev/null; fi
}

# --- helpers -----------------------------------------------------------------
matches() {
  [[ "$1" =~ $MATCH_MODE ]]
}

delete_ip() {
  oci network public-ip delete --public-ip-id "$1" --force >/dev/null 2>&1
}

print_summary() {
  local n=${#matched_ips[@]} i pct
  pct=$(awk -v m="$n" -v t="$checked" 'BEGIN { printf "%.2f", (t > 0) ? m * 100 / t : 0 }')
  echo
  echo "==================== SUMMARY ===================="
  if (( n == 0 )); then
    echo "No matched IPs yet."
  else
    printf '%-3s %-16s %-14s %s\n' "#" "IP" "NAME" "OCID"
    for (( i = 0; i < n; i++ )); do
      printf '%-3s %-16s %-14s %s\n' "$((i + 1))" "${matched_ips[i]}" "${matched_names[i]}" "${matched_ids[i]}"
    done
  fi
  echo "-------------------------------------------------"
  echo "IPs checked : $checked"
  echo "Matched     : $n"
  echo "Match rate  : ${pct}%"
  echo "================================================="
  echo
}

handle_key() {
  case "$1" in
    i|I) print_summary ;;
  esac
}

# Wait for N seconds while listening for keypresses.
wait_and_poll() {
  local secs="$1" key end
  if (( ! HAVE_TTY )); then
    sleep "$secs"
    return
  fi
  end=$(( SECONDS + secs ))
  while (( SECONDS < end )); do
    if read -rsn1 -t 1 key; then
      handle_key "$key"
    fi
  done
}

cleanup() {
  echo
  if [[ -n "$current_id" ]]; then
    echo "Interrupted, deleting $current_id ..."
    delete_ip "$current_id"
    current_id=""
  fi
  print_summary
  exit 130
}
trap cleanup INT TERM
trap restore_tty EXIT

# --- main loop ---------------------------------------------------------------
echo "Match regex: $MATCH_MODE"
echo "Press i for a summary, Ctrl-C to quit."
echo

backoff=10

while :; do
  if (( MAX_TRIES > 0 && checked >= MAX_TRIES )); then
    echo "Reached MAX_TRIES ($MAX_TRIES)."
    print_summary
    exit 0
  fi

  n=$(( checked + 1 ))
  name="ip-hunt-$n"

  # Output is "<ocid> <ip-address>"
  out=$(oci network public-ip create \
          --compartment-id "$COMPARTMENT_ID" \
          --lifetime RESERVED \
          --display-name "$name" \
          --query "join(' ', [data.id, data.\"ip-address\"])" \
          --raw-output 2>&1)
  rc=$?

  if (( rc != 0 )); then
    echo "[$n] create failed (retrying in ${backoff}s): $(echo "$out" | tr '\n' ' ' | cut -c1-200)"
    wait_and_poll "$backoff"
    backoff=$(( backoff < 120 ? backoff * 2 : 120 ))
    continue
  fi
  backoff=10

  read -r id ip <<< "$out"
  current_id="$id"
  checked=$n

  if matches "$ip"; then
    matched_ips+=("$ip")
    matched_names+=("$name")
    matched_ids+=("$id")
    echo "[$n] $ip  <-- match! Keeping it. (${#matched_ips[@]} matched out of $checked)"
    current_id=""
  else
    echo "[$n] $ip  no match, deleting"
    if ! delete_ip "$id"; then
      echo "Warning: failed to delete $id, check it manually." >&2
    fi
    current_id=""
  fi

  wait_and_poll "$SLEEP"
done
