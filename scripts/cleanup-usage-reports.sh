#!/usr/bin/env bash
set -euo pipefail

#
# cleanup-usage-reports.sh
#
# Cleanup script to remove all OCI Usage Reports resources:
#   - Functions applications and functions with name matching patterns from .env + "*"
#   - OCIR repositories with name matching OCIR_REPO_NAME + "*"
#   - VCNs and subnets with name matching VCN_NAME + "*"
#   - Object Storage buckets with name matching BUCKET_NAME + "*"
#
# Patterns are read from scripts/.env (APP_NAME, OCIR_REPO_NAME, VCN_NAME, BUCKET_NAME)
# and "*" is appended for matching. Defaults are used if variables are not set.
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
  local compartment_name="$1"
  local tenancy_ocid="$2"
  
  # Search by name only
  local compartment_id
  compartment_id="$(run_oci iam compartment list \
    --compartment-id "$tenancy_ocid" \
    --compartment-id-in-subtree true \
    --all \
    --query "data[?\"name\"=='${compartment_name}'].id | [0]" \
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
  
  # Get pattern from .env (default to VCN_NAME or OCIR_REPO_NAME, remove -app suffix if present)
  local app_pattern="${APP_NAME:-${VCN_NAME:-${OCIR_REPO_NAME:-oci-usage-reports}}}"
  app_pattern="${app_pattern%-app}"  # Remove -app suffix if present
  app_pattern="$(printf '%s' "$app_pattern" | tr '[:upper:]' '[:lower:]')"  # Convert to lowercase
  
  info "Searching for Functions applications with name matching '${app_pattern}*'..."
  
  local apps
  apps="$(run_oci fn application list \
    --compartment-id "$compartment_id" \
    --all \
    --output json 2>/dev/null | python3 -c "
import sys, json
pattern = '${app_pattern}'.lower()
try:
    data = json.load(sys.stdin).get('data', [])
    for app in data:
        name = app.get('display-name') or app.get('name') or ''
        if name.lower().startswith(pattern):
            print(f\"{app.get('id')}|{name}\")
except Exception:
    pass
" 2>/dev/null || true)"
  
  if [[ -z "$apps" ]]; then
    info "No Functions applications found with name matching '${app_pattern}*'."
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
  
  # Get pattern from .env
  local repo_pattern="${OCIR_REPO_NAME:-oci-usage-reports}"
  repo_pattern="$(printf '%s' "$repo_pattern" | tr '[:upper:]' '[:lower:]')"  # Convert to lowercase
  
  info "Searching for OCIR repositories with name matching '${repo_pattern}*' in compartment and sub-compartments..."
  
  # Get tenancy OCID for recursive compartment search
  local tenancy_ocid
  tenancy_ocid="$(detect_tenancy_ocid || true)"
  
  # Get all compartments including the specified one, tenancy root, and all sub-compartments
  local all_compartments
  if [[ -n "$tenancy_ocid" ]]; then
    all_compartments="$(run_oci iam compartment list \
      --compartment-id "$tenancy_ocid" \
      --compartment-id-in-subtree true \
      --all \
      --output json 2>/dev/null | python3 -c "
import sys, json
target_comp_id = '${compartment_id}'
tenancy_id = '${tenancy_ocid}'
try:
    data = json.load(sys.stdin).get('data', [])
    compartments = [target_comp_id, tenancy_id]  # Include target compartment and tenancy root
    # Find all sub-compartments of the target compartment
    for comp in data:
        comp_id = comp.get('id') or ''
        parent_id = comp.get('compartment-id') or ''
        # If this compartment's parent is the target, or if it's the target itself
        if parent_id == target_comp_id or comp_id == target_comp_id:
            compartments.append(comp_id)
    # Remove duplicates and print (target compartment first, then tenancy root)
    seen = set()
    print(target_comp_id)  # Print target first
    seen.add(target_comp_id)
    if tenancy_id not in seen:
        print(tenancy_id)  # Print tenancy root second
        seen.add(tenancy_id)
    for comp_id in compartments:
        if comp_id and comp_id not in seen:
            print(comp_id)
            seen.add(comp_id)
except Exception:
    print('${compartment_id}')  # Fallback to just the specified compartment
    print('${tenancy_ocid}')  # Also include tenancy root
" 2>/dev/null || echo -e "${compartment_id}\n${tenancy_ocid}")"
  else
    all_compartments="$compartment_id"
  fi
  
  # Search for repositories in all compartments
  local repos
  repos=""
  local compartments_searched=0
  while IFS= read -r comp_id; do
    [[ -z "$comp_id" ]] && continue
    compartments_searched=$((compartments_searched + 1))
    info "  Searching compartment: ${comp_id}"
    
    local comp_repos comp_repos_error
    comp_repos_error="$(run_oci artifacts container repository list \
      --compartment-id "$comp_id" \
      --all \
      --output json 2>&1)"
    local list_exit_code=$?
    
    if [[ $list_exit_code -ne 0 ]]; then
      warn "    Failed to list repositories in compartment ${comp_id}: ${comp_repos_error}"
      continue
    fi
    
    # Parse JSON and extract matching repositories, capturing errors separately
    local parse_error_output
    parse_error_output="$(echo "$comp_repos_error" | python3 -c "
import sys, json
pattern = '${repo_pattern}'.lower()
try:
    json_data = json.load(sys.stdin)
    if not isinstance(json_data, dict):
        print(f'ERROR: Expected dict, got {type(json_data).__name__}', file=sys.stderr)
        sys.exit(0)  # Exit with 0 to avoid triggering set -e
    data = json_data.get('data', [])
    if not isinstance(data, list):
        print(f'ERROR: Expected list in data field, got {type(data).__name__}', file=sys.stderr)
        sys.exit(0)  # Exit with 0 to avoid triggering set -e
    for repo in data:
        if not isinstance(repo, dict):
            continue
        name = repo.get('display-name') or repo.get('name') or ''
        if name.lower().startswith(pattern):
            print(f\"{repo.get('id')}|{name}\")
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(0)  # Exit with 0 to avoid triggering set -e
" 2>&1) || true"
    
    # Separate stdout (repos) from stderr (errors)
    comp_repos="$(echo "$parse_error_output" | grep -v "^ERROR:" || true)"
    local parse_error
    parse_error="$(echo "$parse_error_output" | grep "^ERROR:" || true)"
    
    if [[ -n "$parse_error" ]]; then
      warn "    Error parsing repository list: ${parse_error}"
    fi
    
    # Count repositories found (only lines with | separator)
    local repo_count=0
    if [[ -n "$comp_repos" ]]; then
      repo_count="$(echo "$comp_repos" | grep -c '|' 2>/dev/null || echo "0")"
    fi
    # Ensure repo_count is a clean number (remove any non-digits, take first value)
    repo_count="$(echo "$repo_count" | head -1 | tr -cd '0-9')"
    repo_count="${repo_count:-0}"
    # Validate it's numeric before comparison
    if [[ "$repo_count" =~ ^[0-9]+$ ]] && [[ "$repo_count" -gt 0 ]]; then
      info "    Found ${repo_count} matching repository/repositories"
    fi
    
    if [[ -n "$comp_repos" ]]; then
      if [[ -z "$repos" ]]; then
        repos="$comp_repos"
      else
        repos="${repos}"$'\n'"${comp_repos}"
      fi
    fi
  done <<< "$all_compartments"
  
  info "  Searched ${compartments_searched} compartment(s)"
  
  if [[ -z "$repos" ]]; then
    info "No OCIR repositories found with name matching '${repo_pattern}*'."
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
  
  # Get pattern from .env
  local vcn_pattern="${VCN_NAME:-oci-usage-reports}"
  vcn_pattern="$(printf '%s' "$vcn_pattern" | tr '[:upper:]' '[:lower:]')"  # Convert to lowercase
  
  info "Searching for VCNs with name matching '${vcn_pattern}*'..."
  
  local vcns
  vcns="$(run_oci network vcn list \
    --compartment-id "$compartment_id" \
    --all \
    --output json 2>/dev/null | python3 -c "
import sys, json
pattern = '${vcn_pattern}'.lower()
try:
    data = json.load(sys.stdin).get('data', [])
    for vcn in data:
        name = vcn.get('display-name') or vcn.get('name') or ''
        if name.lower().startswith(pattern):
            print(f\"{vcn.get('id')}|{name}\")
except Exception:
    pass
" 2>/dev/null || true)"
  
  if [[ -z "$vcns" ]]; then
    info "No VCNs found with name matching '${vcn_pattern}*'."
    return 0
  fi
  
  while IFS='|' read -r vcn_id vcn_name; do
    [[ -z "$vcn_id" ]] && continue
    
    info "Found VCN: ${vcn_name} (${vcn_id})"
    
    # Delete all subnets first (they may reference route tables)
    info "  Searching for subnets in VCN..."
    local subnet_pattern="${SUBNET_NAME:-${vcn_pattern}-private}"
    subnet_pattern="${subnet_pattern%-private}"  # Remove -private suffix if present
    subnet_pattern="$(printf '%s' "$subnet_pattern" | tr '[:upper:]' '[:lower:]')"  # Convert to lowercase
    
    local subnets
    subnets="$(run_oci network subnet list \
      --compartment-id "$compartment_id" \
      --vcn-id "$vcn_id" \
      --all \
      --output json 2>/dev/null | python3 -c "
import sys, json
pattern = '${subnet_pattern}'.lower()
try:
    data = json.load(sys.stdin).get('data', [])
    for subnet in data:
        name = subnet.get('display-name') or subnet.get('name') or ''
        if name.lower().startswith(pattern):
            print(f\"{subnet.get('id')}|{name}\")
except Exception:
    pass
" 2>/dev/null || true)"
    
    if [[ -n "$subnets" ]]; then
      while IFS='|' read -r subnet_id subnet_name; do
        [[ -z "$subnet_id" ]] && continue
        info "    Deleting subnet: ${subnet_name} (${subnet_id})"
        if run_oci network subnet delete --subnet-id "$subnet_id" --force >/dev/null 2>&1; then
          info "      ✓ Subnet deleted: ${subnet_name}"
          deleted_resources+=("Subnet: ${subnet_name}")
          deleted_count=$((deleted_count + 1))
        else
          warn "      ✗ Failed to delete subnet ${subnet_name}."
        fi
      done <<< "$subnets"
    fi
    
    # Delete route tables (they may reference service gateways)
    info "  Searching for route tables in VCN..."
    local route_tables
    route_tables="$(run_oci network route-table list \
      --compartment-id "$compartment_id" \
      --vcn-id "$vcn_id" \
      --all \
      --output json 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin).get('data', [])
    for rt in data:
        name = rt.get('display-name') or rt.get('name') or ''
        # Match route tables that might be related (containing vcn name or -private-rt)
        if '${vcn_pattern}' in name.lower() or '-private-rt' in name.lower() or '-rt' in name.lower():
            print(f\"{rt.get('id')}|{name}\")
except Exception:
    pass
" 2>/dev/null || true)"
    
    if [[ -n "$route_tables" ]]; then
      while IFS='|' read -r rt_id rt_name; do
        [[ -z "$rt_id" ]] && continue
        info "    Deleting route table: ${rt_name} (${rt_id})"
        if run_oci network route-table delete --rt-id "$rt_id" --force >/dev/null 2>&1; then
          info "      ✓ Route table deleted: ${rt_name}"
          deleted_resources+=("Route Table: ${rt_name}")
          deleted_count=$((deleted_count + 1))
        else
          warn "      ✗ Failed to delete route table ${rt_name}."
        fi
      done <<< "$route_tables"
    fi
    
    # Delete service gateways
    info "  Searching for service gateways in VCN..."
    local service_gateways
    service_gateways="$(run_oci network service-gateway list \
      --compartment-id "$compartment_id" \
      --vcn-id "$vcn_id" \
      --all \
      --output json 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin).get('data', [])
    for sgw in data:
        name = sgw.get('display-name') or sgw.get('name') or ''
        print(f\"{sgw.get('id')}|{name}\")
except Exception:
    pass
" 2>/dev/null || true)"
    
    if [[ -n "$service_gateways" ]]; then
      while IFS='|' read -r sgw_id sgw_name; do
        [[ -z "$sgw_id" ]] && continue
        info "    Deleting service gateway: ${sgw_name:-unnamed} (${sgw_id})"
        if run_oci network service-gateway delete --service-gateway-id "$sgw_id" --force >/dev/null 2>&1; then
          info "      ✓ Service gateway deleted: ${sgw_name:-unnamed}"
          deleted_resources+=("Service Gateway: ${sgw_name:-unnamed}")
          deleted_count=$((deleted_count + 1))
        else
          warn "      ✗ Failed to delete service gateway ${sgw_name:-unnamed}."
        fi
      done <<< "$service_gateways"
    fi
    
    # Delete VCN (last, after all dependencies are removed)
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

delete_pars() {
  local compartment_id="$1"
  local deleted_count=0
  local deleted_resources=()
  
  # Get namespace
  local namespace
  namespace="$(run_oci os ns get --query 'data' --raw-output 2>/dev/null || true)"
  if [[ -z "$namespace" ]]; then
    warn "Could not determine Object Storage namespace. Skipping PAR deletion."
    return 0
  fi
  
  # Get bucket pattern from .env to find buckets that might have PARs
  local bucket_pattern="${BUCKET_NAME:-copyusagereport}"
  bucket_pattern="$(printf '%s' "$bucket_pattern" | tr '[:upper:]' '[:lower:]')"  # Convert to lowercase
  
  info "Searching for Pre-Authenticated Requests (PARs) for buckets matching '${bucket_pattern}*'..."
  
  # Find buckets matching the pattern
  local buckets
  buckets="$(run_oci os bucket list \
    --compartment-id "$compartment_id" \
    --namespace-name "$namespace" \
    --all \
    --output json 2>/dev/null | python3 -c "
import sys, json
pattern = '${bucket_pattern}'.lower()
try:
    data = json.load(sys.stdin).get('data', [])
    for bucket in data:
        name = bucket.get('name') or ''
        if name.lower().startswith(pattern):
            print(f\"{name}\")
except Exception:
    pass
" 2>/dev/null || true)"
  
  if [[ -z "$buckets" ]]; then
    info "No buckets found with name matching '${bucket_pattern}*'. Skipping PAR deletion."
    return 0
  fi
  
  # For each bucket, find and delete PARs
  while IFS= read -r bucket_name; do
    [[ -z "$bucket_name" ]] && continue
    
    # Find PARs for this bucket
    local pars
    pars="$(run_oci os preauth-request list \
      --namespace-name "$namespace" \
      --bucket-name "$bucket_name" \
      --all \
      --output json 2>/dev/null | python3 -c "
import sys, json
pattern = 'copyusagereport-par-'.lower()
try:
    data = json.load(sys.stdin).get('data', [])
    for par in data:
        name = par.get('name') or ''
        par_id = par.get('id') or ''
        if name.lower().startswith(pattern) and par_id:
            print(f\"{par_id}|{name}\")
except Exception:
    pass
" 2>/dev/null || true)"
    
    if [[ -n "$pars" ]]; then
      while IFS='|' read -r par_id par_name; do
        [[ -z "$par_id" ]] || [[ -z "$par_name" ]] && continue
        
        info "Deleting PAR: ${par_name} (bucket: ${bucket_name})"
        if run_oci os preauth-request delete \
          --bucket-name "$bucket_name" \
          --par-id "$par_id" \
          --force >/dev/null 2>&1; then
          info "  ✓ PAR deleted: ${par_name}"
          deleted_resources+=("PAR: ${par_name} (bucket: ${bucket_name})")
          deleted_count=$((deleted_count + 1))
        else
          warn "  ✗ Failed to delete PAR ${par_name}."
        fi
      done <<< "$pars"
    fi
  done <<< "$buckets"
  
  if [[ ${#deleted_resources[@]} -gt 0 ]]; then
    info "Deleted PARs:"
    for resource in "${deleted_resources[@]}"; do
      info "  - ${resource}"
    done
  fi
  info "Total: ${deleted_count} PAR(s) deleted."
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
  
  # Get pattern from .env
  local bucket_pattern="${BUCKET_NAME:-copyusagereport}"
  bucket_pattern="$(printf '%s' "$bucket_pattern" | tr '[:upper:]' '[:lower:]')"  # Convert to lowercase
  
  info "Searching for Object Storage buckets with name matching '${bucket_pattern}*'..."
  
  local buckets
  buckets="$(run_oci os bucket list \
    --compartment-id "$compartment_id" \
    --namespace-name "$namespace" \
    --all \
    --output json 2>/dev/null | python3 -c "
import sys, json
pattern = '${bucket_pattern}'.lower()
try:
    data = json.load(sys.stdin).get('data', [])
    for bucket in data:
        name = bucket.get('name') or ''
        if name.lower().startswith(pattern):
            print(f\"{name}\")
except Exception:
    pass
" 2>/dev/null || true)"
  
  if [[ -z "$buckets" ]]; then
    info "No buckets found with name matching '${bucket_pattern}*'."
    return 0
  fi
  
  while IFS= read -r bucket_name; do
    [[ -z "$bucket_name" ]] && continue
    
    info "Deleting bucket: ${bucket_name}"
    
    # First, delete all objects in the bucket
    info "  Listing objects in bucket..."
    info "    Command: oci os object list --bucket-name '${bucket_name}' --namespace-name '${namespace}' --all --output json"
    local objects_deleted=0
    local objects
    local list_error
    list_error="$(run_oci os object list \
      --bucket-name "$bucket_name" \
      --namespace-name "$namespace" \
      --all \
      --output json 2>&1)"
    local list_exit_code=$?
    
    info "    Exit code: ${list_exit_code}"
    if [[ ${list_exit_code} -ne 0 ]]; then
      warn "    Failed to list objects: ${list_error}"
    else
      # Show raw JSON for debugging (first 500 chars)
      local json_preview
      json_preview="$(echo "$list_error" | head -c 500)"
      info "    JSON preview: ${json_preview}..."
      
      objects="$(echo "$list_error" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    # Try different possible structures
    obj_list = []
    if isinstance(data, dict):
        if 'data' in data:
            if isinstance(data['data'], dict) and 'objects' in data['data']:
                obj_list = data['data']['objects']
            elif isinstance(data['data'], list):
                obj_list = data['data']
        elif 'objects' in data:
            obj_list = data['objects']
    elif isinstance(data, list):
        obj_list = data
    
    for obj in obj_list:
        name = obj.get('name') or obj.get('display-name') or ''
        if name:
            print(name)
except Exception as e:
    sys.stderr.write(f'Error parsing JSON: {e}\n')
    pass
" 2>&1)"
      
      local parse_error
      parse_error="$(echo "$objects" | grep -i "error" || true)"
      if [[ -n "$parse_error" ]]; then
        warn "    JSON parsing error: ${parse_error}"
      fi
      
      if [[ -n "$objects" ]]; then
        local object_count
        object_count="$(echo "$objects" | wc -l | tr -d ' ')"
        info "    Found ${object_count} object(s) to delete..."
        while IFS= read -r object_name; do
          [[ -z "$object_name" ]] && continue
          local delete_err delete_exit_code
          delete_err="$(run_oci os object delete \
            --bucket-name "$bucket_name" \
            --namespace-name "$namespace" \
            --object-name "$object_name" \
            --force 2>&1)"
          delete_exit_code=$?
          if [[ $delete_exit_code -eq 0 ]]; then
            objects_deleted=$((objects_deleted + 1))
          else
            warn "      Failed to delete object '${object_name}': ${delete_err}"
          fi
        done <<< "$objects"
        if [[ $objects_deleted -gt 0 ]]; then
          info "    ✓ Deleted ${objects_deleted} of ${object_count} object(s)"
        fi
        if [[ $objects_deleted -lt $object_count ]]; then
          warn "    ⚠ Only deleted ${objects_deleted} of ${object_count} object(s). Some objects may still exist."
        fi
      else
        info "    Bucket is empty (no objects found)"
      fi
    fi
    
    
    # Verify bucket is empty before attempting deletion
    info "  Verifying bucket is empty..."
    local remaining_check remaining_check_error
    remaining_check_error="$(run_oci os object list \
      --bucket-name "$bucket_name" \
      --namespace-name "$namespace" \
      --all \
      --output json 2>&1)"
    local remaining_check_exit_code=$?
    
    if [[ $remaining_check_exit_code -ne 0 ]]; then
      warn "    Warning: Failed to verify bucket contents: ${remaining_check_error}"
    else
      remaining_check="$(echo "$remaining_check_error" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin).get('data', {}).get('objects', [])
    print(len(data))
except Exception:
    print(0)
" 2>/dev/null | tr -d '[:space:]' || echo "0")"
      
      remaining_check=$((remaining_check + 0))
      if [[ $remaining_check -gt 0 ]]; then
        warn "  ✗ Cannot delete bucket ${bucket_name}: still contains ${remaining_check} object(s)."
        warn "    Please delete objects manually or check permissions."
        continue
      fi
      info "    Bucket verification: empty (0 objects)"
    fi
    
    # Now delete the bucket itself
    info "  Attempting to delete bucket..."
    info "    Command: oci os bucket delete --bucket-name '${bucket_name}' --namespace-name '${namespace}' --force"
    local delete_error delete_exit_code
    delete_error="$(run_oci os bucket delete \
      --bucket-name "$bucket_name" \
      --namespace-name "$namespace" \
      --force 2>&1)"
    delete_exit_code=$?
    
    info "    Exit code: ${delete_exit_code}"
    if [[ -n "$delete_error" ]]; then
      info "    CLI output: ${delete_error}"
    fi
    
    if [[ $delete_exit_code -eq 0 ]]; then
      info "  ✓ Bucket deleted: ${bucket_name}"
      deleted_resources+=("Bucket: ${bucket_name}")
      deleted_count=$((deleted_count + 1))
    else
      warn "  ✗ Failed to delete bucket ${bucket_name}."
      if [[ -n "$delete_error" ]]; then
        warn "    Error: ${delete_error}"
      fi
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
  # Get patterns from .env
  local app_pattern="${APP_NAME:-${VCN_NAME:-${OCIR_REPO_NAME:-oci-usage-reports}}}"
  app_pattern="${app_pattern%-app}"
  local repo_pattern="${OCIR_REPO_NAME:-oci-usage-reports}"
  local vcn_pattern="${VCN_NAME:-oci-usage-reports}"
  local bucket_pattern="${BUCKET_NAME:-copyusagereport}"
  
  info "Cleanup OCI Usage Reports Resources"
  info "This will remove:"
  info "  - Functions applications and functions with name matching '${app_pattern}*'"
  info "  - OCIR repositories with name matching '${repo_pattern}*'"
  info "  - VCNs and subnets with name matching '${vcn_pattern}*'"
  info "  - Object Storage buckets with name matching '${bucket_pattern}*'"
  echo
  
  # Setup OCI CLI context
  setup_oci_cli_context
  
  # Get tenancy OCID
  local tenancy_ocid
  tenancy_ocid="$(detect_tenancy_ocid || true)"
  if [[ -z "$tenancy_ocid" ]]; then
    error "Could not detect tenancy OCID from OCI CLI config. Please ensure 'tenancy=' is set in your OCI CLI profile."
  fi
  
  # Get compartment with retry loop
  local compartment_name="" compartment_id=""
  while true; do
    compartment_name="$(prompt_default 'Enter compartment name' "${COMPARTMENT_NAME:-}")"
    if [[ -z "$compartment_name" ]]; then
      warn "Compartment name cannot be empty."
      continue
    fi
    
    info "Resolving compartment '${compartment_name}'..."
    compartment_id="$(get_compartment_id "$compartment_name" "$tenancy_ocid" || true)"
    if [[ -z "$compartment_id" ]]; then
      warn "Could not find compartment with name '${compartment_name}' under tenancy '${tenancy_ocid}'."
      if ! confirm "Try again with a different compartment name?" "y"; then
        error "Compartment resolution cancelled."
      fi
      continue
    fi
    break
  done
  
  compartment_name="$(run_oci iam compartment get --compartment-id "$compartment_id" --query 'data.name' --raw-output 2>/dev/null || true)"
  info "Using compartment: ${compartment_name:-$compartment_id}"
  echo
  
  # Confirm deletion
  if ! confirm "Delete all matching resources in compartment '${compartment_name:-$compartment_id}'?" "n"; then
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
  delete_pars "$compartment_id"
  echo
  delete_buckets "$compartment_id"
  echo
  
  info "Cleanup completed."
}

main "$@"
