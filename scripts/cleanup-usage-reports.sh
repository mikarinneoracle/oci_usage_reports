#!/usr/bin/env bash
set -euo pipefail

#
# cleanup-usage-reports.sh
#
# Cleanup script to remove all OCI Usage Reports resources:
#   - Functions applications and functions with name matching "oci-usage-reports*"
#   - OCIR repositories with name matching "oci-usage-reports*"
#   - VCNs and subnets with name matching "oci-usage-reports*"
#   - Object Storage buckets with name matching "copyusagereport*"
#
# This script uses OCI CLI authentication only (not Resource Principal).
# Run from the repository root or scripts directory.
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Optional: load defaults from .env
if [[ -f "${SCRIPT_DIR}/.env" ]] && [[ -r "${SCRIPT_DIR}/.env" ]]; then
  set +u
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/.env"
  set -u
fi

# Global OCI CLI config context
OCI_CLI_CONFIG_PATH=""
OCI_CLI_PROFILE_NAME=""

# Run OCI CLI with optional config/profile
run_oci() {
  if [[ -n "${OCI_CLI_CONFIG_PATH:-}" ]] || [[ -n "${OCI_CLI_PROFILE_NAME:-}" ]]; then
    local oci_extra=()
    [[ -n "${OCI_CLI_CONFIG_PATH:-}" ]] && oci_extra+=(--config-file "$OCI_CLI_CONFIG_PATH")
    [[ -n "${OCI_CLI_PROFILE_NAME:-}" ]] && oci_extra+=(--profile "$OCI_CLI_PROFILE_NAME")
    oci "${oci_extra[@]}" "$@"
  else
    oci "$@"
  fi
}

info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*" >&2; }
error() { echo "[ERROR] $*" >&2; exit 1; }

check_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    error "Required command '$cmd' not found in PATH. Please install it before continuing."
  fi
}

prompt_default() {
  local prompt="$1"
  local default="${2:-}"
  local result
  if [[ -n "$default" ]]; then
    read -r -p "${prompt} [${default}]: " result || true
    echo "${result:-$default}"
  else
    read -r -p "${prompt}: " result || true
    echo "$result"
  fi
}

confirm() {
  local prompt="$1"
  local default="${2:-n}"
  local label
  case "$default" in
    y|Y|yes|Yes|YES) label="Y/n" ;;
    *) label="y/N" ;;
  esac
  local response
  read -r -p "${prompt} [${label}]: " response || true
  response="${response:-$default}"
  case "$response" in
    y|Y|yes|Yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

setup_oci_cli_context() {
  info "Configuring OCI CLI context"

  local default_config="${OCI_CLI_CONFIG_FILE:-$HOME/.oci/config}"
  local cfg

  read -r -p "Enter OCI CLI config path [${default_config}]: " cfg || true
  cfg="${cfg:-$default_config}"

  if [[ ! -f "$cfg" ]]; then
    error "OCI CLI config not found at '${cfg}'. Install and configure OCI CLI first: https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm"
  fi

  OCI_CLI_CONFIG_PATH="$cfg"

  # List available profiles
  local profiles
  profiles=($(awk '/^\[.*\]/{gsub(/[\[\]]/,"",$1); print $1}' "$OCI_CLI_CONFIG_PATH"))

  if [[ ${#profiles[@]} -eq 0 ]]; then
    error "No profiles found in OCI CLI config '${OCI_CLI_CONFIG_PATH}'. Please run 'oci setup config' first."
  fi

  if [[ ${#profiles[@]} -eq 1 ]]; then
    OCI_CLI_PROFILE_NAME="${profiles[0]}"
    info "Using profile: ${OCI_CLI_PROFILE_NAME}"
  else
    info "Available profiles:"
    local i=1
    for p in "${profiles[@]}"; do
      echo "  ${i}) ${p}"
      i=$((i + 1))
    done
    local choice
    choice="$(prompt_default 'Select profile' "${profiles[0]}")"
    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#profiles[@]} ]]; then
      OCI_CLI_PROFILE_NAME="${profiles[$((choice - 1))]}"
    else
      OCI_CLI_PROFILE_NAME="$choice"
    fi
    info "Using profile: ${OCI_CLI_PROFILE_NAME}"
  fi
}

detect_tenancy_ocid() {
  # Try to detect tenancy OCID from OCI CLI config.
  # Uses interactive context (OCI_CLI_CONFIG_PATH / OCI_CLI_PROFILE_NAME) if set.
  local profile config

  if [[ -n "$OCI_CLI_CONFIG_PATH" && -n "$OCI_CLI_PROFILE_NAME" ]]; then
    config="$OCI_CLI_CONFIG_PATH"
    profile="$OCI_CLI_PROFILE_NAME"
  else
    profile="${OCI_CLI_PROFILE:-DEFAULT}"
    config="${OCI_CLI_CONFIG_FILE:-$HOME/.oci/config}"
  fi

  if [[ ! -f "$config" ]]; then
    return 1
  fi

  awk -v prof="[$profile]" '
    $0 == prof { in_profile=1; next }
    /^\[/ { in_profile=0 }
    in_profile && $0 ~ /^[[:space:]]*tenancy[[:space:]]*=/ {
      split($0, a, "=")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", a[2])
      print a[2]
      exit
    }
  ' "$config"
}

get_compartment_id() {
  local compartment_input="$1"
  local tenancy_ocid="$2"
  
  # If it looks like an OCID, use it directly
  if [[ "$compartment_input" =~ ^ocid1\. ]]; then
    echo "$compartment_input"
    return 0
  fi
  
  # Otherwise, search by name
  local compartment_id
  compartment_id="$(run_oci iam compartment list \
    --compartment-id "$tenancy_ocid" \
    --compartment-id-in-subtree true \
    --all \
    --query "data[?\"name\"=='${compartment_input}'].id | [0]" \
    --raw-output 2>/dev/null || true)"
  
  if [[ -n "$compartment_id" && "$compartment_id" != "null" ]]; then
    echo "$compartment_id"
    return 0
  fi
  
  return 1
}

delete_functions() {
  local compartment_id="$1"
  local deleted_count=0
  local deleted_resources=()
  
  info "Searching for Functions applications with name matching 'oci-usage-reports*'..."
  
  local apps
  apps="$(run_oci fn application list \
    --compartment-id "$compartment_id" \
    --all \
    --output json 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin).get('data', [])
    for app in data:
        name = app.get('display-name') or app.get('name') or ''
        if name.lower().startswith('oci-usage-reports'):
            print(f\"{app.get('id')}|{name}\")
except Exception:
    pass
" 2>/dev/null || true)"
  
  if [[ -z "$apps" ]]; then
    info "No Functions applications found with name matching 'oci-usage-reports*'."
    return 0
  fi
  
  while IFS='|' read -r app_id app_name; do
    [[ -z "$app_id" ]] && continue
    
    info "Found application: ${app_name} (${app_id})"
    
    # List functions in this application
    local functions
    functions="$(run_oci fn function list \
      --application-id "$app_id" \
      --all \
      --output json 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin).get('data', [])
    for func in data:
        print(f\"{func.get('id')}|{func.get('display-name') or func.get('name') or ''}\")
except Exception:
    pass
" 2>/dev/null || true)"
    
    # Delete functions first
    if [[ -n "$functions" ]]; then
      while IFS='|' read -r func_id func_name; do
        [[ -z "$func_id" ]] && continue
        info "  Deleting function: ${func_name} (${func_id})"
        if run_oci fn function delete --function-id "$func_id" --force >/dev/null 2>&1; then
          info "    ✓ Function deleted: ${func_name}"
          deleted_resources+=("Function: ${func_name}")
          deleted_count=$((deleted_count + 1))
        else
          warn "    ✗ Failed to delete function ${func_name}."
        fi
      done <<< "$functions"
    fi
    
    # Delete application
    info "  Deleting application: ${app_name}"
    if run_oci fn application delete --application-id "$app_id" --force >/dev/null 2>&1; then
      info "    ✓ Application deleted: ${app_name}"
      deleted_resources+=("Application: ${app_name}")
      deleted_count=$((deleted_count + 1))
    else
      warn "    ✗ Failed to delete application ${app_name}."
    fi
  done <<< "$apps"
  
  if [[ ${#deleted_resources[@]} -gt 0 ]]; then
    info "Deleted Functions resources:"
    for resource in "${deleted_resources[@]}"; do
      info "  - ${resource}"
    done
  fi
  info "Total: ${deleted_count} Functions resource(s) deleted."
}

delete_ocir_repos() {
  local compartment_id="$1"
  local deleted_count=0
  local deleted_resources=()
  
  info "Searching for OCIR repositories with name matching 'oci-usage-reports*'..."
  
  local repos
  repos="$(run_oci artifacts container repository list \
    --compartment-id "$compartment_id" \
    --all \
    --output json 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin).get('data', [])
    for repo in data:
        name = repo.get('display-name') or repo.get('name') or ''
        if name.lower().startswith('oci-usage-reports'):
            print(f\"{repo.get('id')}|{name}\")
except Exception:
    pass
" 2>/dev/null || true)"
  
  if [[ -z "$repos" ]]; then
    info "No OCIR repositories found with name matching 'oci-usage-reports*'."
    return 0
  fi
  
  while IFS='|' read -r repo_id repo_name; do
    [[ -z "$repo_id" ]] && continue
    
    info "Deleting repository: ${repo_name} (${repo_id})"
    if run_oci artifacts container repository delete --repository-id "$repo_id" --force >/dev/null 2>&1; then
      info "  ✓ Repository deleted: ${repo_name}"
      deleted_resources+=("OCIR Repository: ${repo_name}")
      deleted_count=$((deleted_count + 1))
    else
      warn "  ✗ Failed to delete repository ${repo_name}."
    fi
  done <<< "$repos"
  
  if [[ ${#deleted_resources[@]} -gt 0 ]]; then
    info "Deleted OCIR repositories:"
    for resource in "${deleted_resources[@]}"; do
      info "  - ${resource}"
    done
  fi
  info "Total: ${deleted_count} OCIR repository/repositories deleted."
}

delete_networks() {
  local compartment_id="$1"
  local deleted_count=0
  local deleted_resources=()
  
  info "Searching for VCNs with name matching 'oci-usage-reports*'..."
  
  local vcns
  vcns="$(run_oci network vcn list \
    --compartment-id "$compartment_id" \
    --all \
    --output json 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin).get('data', [])
    for vcn in data:
        name = vcn.get('display-name') or vcn.get('name') or ''
        if name.lower().startswith('oci-usage-reports'):
            print(f\"{vcn.get('id')}|{name}\")
except Exception:
    pass
" 2>/dev/null || true)"
  
  if [[ -z "$vcns" ]]; then
    info "No VCNs found with name matching 'oci-usage-reports*'."
    return 0
  fi
  
  while IFS='|' read -r vcn_id vcn_name; do
    [[ -z "$vcn_id" ]] && continue
    
    info "Found VCN: ${vcn_name} (${vcn_id})"
    
    # List subnets in this VCN
    local subnets
    subnets="$(run_oci network subnet list \
      --compartment-id "$compartment_id" \
      --vcn-id "$vcn_id" \
      --all \
      --output json 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin).get('data', [])
    for subnet in data:
        name = subnet.get('display-name') or subnet.get('name') or ''
        if name.lower().startswith('oci-usage-reports'):
            print(f\"{subnet.get('id')}|{name}\")
except Exception:
    pass
" 2>/dev/null || true)"
    
    # Delete subnets first
    if [[ -n "$subnets" ]]; then
      while IFS='|' read -r subnet_id subnet_name; do
        [[ -z "$subnet_id" ]] && continue
        info "  Deleting subnet: ${subnet_name} (${subnet_id})"
        if run_oci network subnet delete --subnet-id "$subnet_id" --force >/dev/null 2>&1; then
          info "    ✓ Subnet deleted: ${subnet_name}"
          deleted_resources+=("Subnet: ${subnet_name}")
          deleted_count=$((deleted_count + 1))
        else
          warn "    ✗ Failed to delete subnet ${subnet_name}."
        fi
      done <<< "$subnets"
    fi
    
    # Delete VCN
    info "  Deleting VCN: ${vcn_name}"
    if run_oci network vcn delete --vcn-id "$vcn_id" --force >/dev/null 2>&1; then
      info "    ✓ VCN deleted: ${vcn_name}"
      deleted_resources+=("VCN: ${vcn_name}")
      deleted_count=$((deleted_count + 1))
    else
      warn "    ✗ Failed to delete VCN ${vcn_name}."
    fi
  done <<< "$vcns"
  
  if [[ ${#deleted_resources[@]} -gt 0 ]]; then
    info "Deleted network resources:"
    for resource in "${deleted_resources[@]}"; do
      info "  - ${resource}"
    done
  fi
  info "Total: ${deleted_count} network resource(s) deleted."
}

delete_buckets() {
  local compartment_id="$1"
  local deleted_count=0
  local deleted_resources=()
  
  # Get namespace
  local namespace
  namespace="$(run_oci os ns get --query 'data' --raw-output 2>/dev/null || true)"
  if [[ -z "$namespace" ]]; then
    warn "Could not determine Object Storage namespace. Skipping bucket deletion."
    return 0
  fi
  
  info "Searching for Object Storage buckets with name matching 'copyusagereport*'..."
  
  local buckets
  buckets="$(run_oci os bucket list \
    --compartment-id "$compartment_id" \
    --namespace-name "$namespace" \
    --all \
    --output json 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin).get('data', [])
    for bucket in data:
        name = bucket.get('name') or ''
        if name.lower().startswith('copyusagereport'):
            print(f\"{name}\")
except Exception:
    pass
" 2>/dev/null || true)"
  
  if [[ -z "$buckets" ]]; then
    info "No buckets found with name matching 'copyusagereport*'."
    return 0
  fi
  
  while IFS= read -r bucket_name; do
    [[ -z "$bucket_name" ]] && continue
    
    info "Deleting bucket: ${bucket_name}"
    if run_oci os bucket delete \
      --bucket-name "$bucket_name" \
      --namespace-name "$namespace" \
      --force >/dev/null 2>&1; then
      info "  ✓ Bucket deleted: ${bucket_name}"
      deleted_resources+=("Bucket: ${bucket_name}")
      deleted_count=$((deleted_count + 1))
    else
      warn "  ✗ Failed to delete bucket ${bucket_name}."
    fi
  done <<< "$buckets"
  
  if [[ ${#deleted_resources[@]} -gt 0 ]]; then
    info "Deleted buckets:"
    for resource in "${deleted_resources[@]}"; do
      info "  - ${resource}"
    done
  fi
  info "Total: ${deleted_count} bucket(s) deleted."
}

main() {
  info "Cleanup OCI Usage Reports Resources"
  info "This will remove:"
  info "  - Functions applications and functions with name matching 'oci-usage-reports*'"
  info "  - OCIR repositories with name matching 'oci-usage-reports*'"
  info "  - VCNs and subnets with name matching 'oci-usage-reports*'"
  info "  - Object Storage buckets with name matching 'copyusagereport*'"
  echo
  
  # Setup OCI CLI context
  setup_oci_cli_context
  
  # Get tenancy OCID
  local tenancy_ocid
  tenancy_ocid="$(detect_tenancy_ocid || true)"
  if [[ -z "$tenancy_ocid" ]]; then
    error "Could not detect tenancy OCID from OCI CLI config. Please ensure 'tenancy=' is set in your OCI CLI profile."
  fi
  
  # Get compartment
  local compartment_input compartment_id compartment_name
  compartment_input="$(prompt_default 'Enter compartment name or OCID' "${COMPARTMENT_NAME:-}")"
  [[ -z "$compartment_input" ]] && error "Compartment name or OCID is required."
  
  compartment_id="$(get_compartment_id "$compartment_input" "$tenancy_ocid" || true)"
  if [[ -z "$compartment_id" ]]; then
    error "Could not find compartment '${compartment_input}'. Check the name or OCID."
  fi
  
  compartment_name="$(run_oci iam compartment get --compartment-id "$compartment_id" --query 'data.name' --raw-output 2>/dev/null || true)"
  info "Using compartment: ${compartment_name:-$compartment_id}"
  echo
  
  # Confirm deletion
  if ! confirm "Delete all 'oci-usage-reports*' resources in compartment '${compartment_name:-$compartment_id}'?" "n"; then
    info "Cleanup cancelled."
    exit 0
  fi
  
  echo
  info "Starting cleanup..."
  echo
  
  # Delete resources
  delete_functions "$compartment_id"
  echo
  delete_ocir_repos "$compartment_id"
  echo
  delete_networks "$compartment_id"
  echo
  delete_buckets "$compartment_id"
  echo
  
  info "Cleanup completed."
}

main "$@"
