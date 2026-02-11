#!/usr/bin/env bash
set -euo pipefail

#
# install-usage-reports.sh
#
# Helper script to install the usage report functions in three ways:
#   1) Prebuilt images to OCI using Fn CLI (recommended)
#   2) Build from source and deploy to OCI with Fn CLI
#   3) Build and run locally with Fn server and OCI CLI credentials
#
# This script is intended to be run from the repository root.
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Optional: load defaults for prompts (e.g. INSTALLER_CHOICE=2, COMPARTMENT_NAME=..., ARCH=arm)
if [[ -f "${SCRIPT_DIR}/.env" ]] && [[ -r "${SCRIPT_DIR}/.env" ]]; then
  set +u
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/.env"
  set -u
fi

# Global OCI CLI config context (set by setup_oci_cli_context)
OCI_CLI_CONFIG_PATH=""
OCI_CLI_PROFILE_NAME=""
# Global Functions application/function OCIDs (set by create_functions_application / install_prebuilt_with_fn)
FN_APP_ID=""
FN_COPY_ID=""
FN_XTEN_ID=""
# If create_ocir_auth_token just generated a token, it is stored here for use as default in ocir_docker_login.
OCIR_AUTH_TOKEN=""

# Run OCI CLI with optional config/profile (avoids "unbound variable" when args are empty under set -u)
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

# Same as run_oci but with optional --region (e.g. for network service list)
run_oci_region() {
  local region_key="${1:-}"
  shift
  if [[ -n "${OCI_CLI_CONFIG_PATH:-}" ]] || [[ -n "${OCI_CLI_PROFILE_NAME:-}" ]] || [[ -n "$region_key" ]]; then
    local oci_extra=()
    [[ -n "${OCI_CLI_CONFIG_PATH:-}" ]] && oci_extra+=(--config-file "$OCI_CLI_CONFIG_PATH")
    [[ -n "${OCI_CLI_PROFILE_NAME:-}" ]] && oci_extra+=(--profile "$OCI_CLI_PROFILE_NAME")
    [[ -n "$region_key" ]] && oci_extra+=(--region "$region_key")
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

  info "Available OCI CLI profiles in ${OCI_CLI_CONFIG_PATH}: ${profiles[*]}"

  local suggested_profile="${OCI_CLI_PROFILE:-DEFAULT}"
  local prof
  read -r -p "Enter OCI CLI profile [${suggested_profile}]: " prof || true
  prof="${prof:-$suggested_profile}"

  # Simple validation: check if chosen profile exists
  local found=0
  for p in "${profiles[@]}"; do
    if [[ "$p" == "$prof" ]]; then
      found=1
      break
    fi
  done

  if [[ $found -eq 0 ]]; then
    warn "Profile '${prof}' not found in '${OCI_CLI_CONFIG_PATH}'. Continuing, but OCI region auto-detection may fail."
  fi

  OCI_CLI_PROFILE_NAME="$prof"
}

detect_default_region() {
  # Try to detect default OCI region from OCI CLI config.
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
    in_profile && $0 ~ /^[[:space:]]*region[[:space:]]*=/ {
      split($0, a, "=")
      # Trim whitespace around value
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", a[2])
      print a[2]
      exit
    }
  ' "$config"
}

detect_default_namespace() {
  # Try to detect OCIR / Object Storage namespace using OCI CLI.
  if ! command -v oci >/dev/null 2>&1; then
    return 1
  fi
  run_oci os ns get --query 'data' --raw-output 2>/dev/null || return 1
}

detect_default_user_ocid() {
  # Try to detect default user OCID from OCI CLI config.
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
    in_profile && $0 ~ /^[[:space:]]*user[[:space:]]*=/ {
      split($0, a, "=")
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", a[2])
      print a[2]
      exit
    }
  ' "$config"
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

list_identity_domain_names() {
  # List identity domain labels in the tenancy (root compartment) for a given home region. One per line.
  # Uses the same labels as Cloud UI (e.g. OracleIdentityCloudService, Default).
  # Filters by home-region matching the selected OCI region key when provided.
  local tenancy_ocid="$1"
  local region_key="${2:-}"
  if [[ -z "$tenancy_ocid" ]] || ! command -v oci >/dev/null 2>&1; then
    return 1
  fi
  run_oci iam domain list --compartment-id "$tenancy_ocid" --all --output json 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin).get('data', [])
    for d in data:
        home = d.get('home-region') or ''
        if '${region_key}' and home != '${region_key}':
            continue
        label = d.get('display-name') or d.get('name') or ''
        if label:
            print(label)
except Exception:
    pass
" || return 1
}

create_ocir_auth_token() {
  # Create a new OCIR auth token via OCI CLI for the selected user.
  if ! command -v oci >/dev/null 2>&1; then
    warn "OCI CLI not available; cannot create auth token automatically."
    return 1
  fi

  local user_ocid desc token default_user
  # Use .env (USER_OCID) or CLI config; no prompt when we have a value.
  default_user="${USER_OCID:-$(detect_default_user_ocid || true)}"
  if [[ -n "$default_user" ]]; then
    user_ocid="$default_user"
    info "Using user OCID from CLI config."
  else
    user_ocid="$(prompt_default 'Enter user OCID for OCIR auth token' "")"
  fi
  if [[ -z "$user_ocid" ]]; then
    warn "User OCID not provided; skipping automatic auth token creation."
    return 1
  fi

  desc="$(prompt_default 'Enter description for new OCIR auth token' 'oci-usage-reports-ocir-token')"

  info "Creating OCIR auth token via OCI CLI..."
  token="$(run_oci iam auth-token create \
      --user-id "$user_ocid" \
      --description "$desc" \
      --query 'data.token' \
      --raw-output 2>/dev/null || true)"

  if [[ -z "$token" ]]; then
    warn "Failed to create auth token via OCI CLI. Check your permissions and try manually from the OCI Console."
    return 1
  fi

  # Make token available as default for the following OCIR Docker login (script can read it; user does not need to re-enter).
  OCIR_AUTH_TOKEN="$token"

  echo
  warn "New OCIR auth token (store this securely; OCI will not show it again):"
  echo "$token"
  echo
  warn "Use this token as the PASSWORD when running 'docker login <region-key>.ocir.io'."
}

create_functions_application() {
  # Create an OCI Functions application via OCI CLI, using the configured
  # OCI CLI config/profile. Shape is set from selected architecture (x86 -> GENERIC_X86, arm -> GENERIC_ARM).
  # Prompts for application name *after* resolving compartment and ensures it does not already exist there.
  # Sets global FN_APP_ID to the created application's OCID.
  local arch_tag="${1:-x86}"
  local shape
  case "$arch_tag" in
    arm) shape="GENERIC_ARM" ;;
    *)   shape="GENERIC_X86" ;;
  esac

  if ! command -v oci >/dev/null 2>&1; then
    error "OCI CLI not available; cannot create Functions application automatically."
  fi

  info "Creating OCI Functions application via OCI CLI (architecture: ${arch_tag})."

  local tenancy_ocid
  tenancy_ocid="$(detect_tenancy_ocid || true)"
  if [[ -z "$tenancy_ocid" ]]; then
    error "Could not detect tenancy OCID from OCI CLI config. Please ensure 'tenancy=' is set in your OCI CLI profile."
  fi

  local compartment_name compartment_id desc existing_app
  while true; do
    compartment_name="$(prompt_default 'Enter compartment name for the Functions application' "${COMPARTMENT_NAME:-}")"
    if [[ -z "$compartment_name" ]]; then
      warn "Compartment name cannot be empty."
      continue
    fi
    break
  done

  info "Resolving compartment '${compartment_name}'..."
  compartment_id="$(
    run_oci iam compartment list \
      --compartment-id "$tenancy_ocid" \
      --compartment-id-in-subtree true \
      --all \
      --query "data[?\"name\"=='${compartment_name}'].id | [0]" \
      --raw-output 2>/dev/null || true
  )"

  if [[ -z "$compartment_id" || "$compartment_id" == "null" ]]; then
    error "Could not find compartment with name '${compartment_name}' under tenancy '${tenancy_ocid}'."
  fi

  # Prompt for Functions application name after resolving compartment and ensure it does not already exist there.
  while true; do
    app_name="$(prompt_default 'Enter Functions application name' "${APP_NAME:-oci-usage-reports-app}")"
    if [[ -z "$app_name" ]]; then
      warn "Application name cannot be empty."
      continue
    fi

    info "Checking if Fn application '${app_name}' already exists in compartment '${compartment_name}'..."
    existing_app="$(
      run_oci fn application list \
        --compartment-id "$compartment_id" \
        --all \
        --query "data[?\"display-name\"=='${app_name}'].id | [0]" \
        --raw-output 2>/dev/null || true
    )"
    if [[ -n "$existing_app" && "$existing_app" != "null" ]]; then
      warn "Application '${app_name}' already exists in compartment '${compartment_name}'. Please choose a different application name."
      continue
    fi
    break
  done

  # Check if any VCNs exist in the compartment, then ask create vs select existing.
  info "Checking for existing VCNs in compartment '${compartment_name}'..."
  local vcn_count
  vcn_count="$(run_oci network vcn list \
    --compartment-id "$compartment_id" \
    --all \
    --query 'length(data)' \
    --raw-output 2>/dev/null || echo "0")"
  if [[ -z "$vcn_count" || "$vcn_count" == "null" ]]; then
    vcn_count="0"
  fi

  local create_vcn_answer subnet_id
  while true; do
    if [[ "$vcn_count" -gt 0 ]]; then
      echo "  1) Create new VCN with private subnet"
      echo "  2) Select existing private subnet"
      create_vcn_answer="$(prompt_default 'Enter choice' '1')"
    else
      info "No VCNs found in compartment. Create new VCN with private subnet, or select existing private subnet (e.g. in another compartment)."
      echo "  1) Create new VCN with private subnet"
      echo "  2) Select existing private subnet"
      create_vcn_answer="$(prompt_default 'Enter choice' '1')"
    fi

    if [[ "$create_vcn_answer" == "2" ]]; then
      info "Listing existing private subnets in compartment '${compartment_name}'..."
      local subnet_names subnet_ids choice idx
      subnet_ids=()
      subnet_names=()
      while IFS=$'\t' read -r sid sname; do
        [[ -z "$sid" || "$sid" != ocid* ]] && continue
        subnet_ids+=("$sid")
        subnet_names+=("${sname:-}")
      done < <(run_oci network subnet list \
        --compartment-id "$compartment_id" \
        --all \
        --output json 2>/dev/null | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin).get('data', [])
    for s in data:
        if s.get('prohibit-public-ip-on-vnic') == True:
            print(s.get('id', '') + '\t' + s.get('display-name', ''))
except Exception:
    pass
")

      if [[ ${#subnet_ids[@]} -eq 0 ]]; then
        warn "No private subnets found in compartment. Choose option 1 to create a new VCN."
        continue
      fi

      idx=0
      for name in "${subnet_names[@]}"; do
        idx=$((idx + 1))
        echo "  ${idx}) ${name}"
      done
      while true; do
        read -r -p "Enter choice (number): " choice || true
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#subnet_ids[@]} ]]; then
          subnet_id="${subnet_ids[$((choice - 1))]}"
          break
        fi
        warn "Please enter a number between 1 and ${#subnet_ids[@]}."
      done
      info "Ensure this subnet has a route to Oracle Services Network (e.g. via a Service Gateway) so the function can pull images from OCIR."
      break
    fi

    # Create new VCN: prompt for name and check if it already exists in compartment
    local vcn_name subnet_name vcn_cidr subnet_cidr vcn_id existing_vcn_id
    while true; do
      vcn_name="$(prompt_default 'Enter VCN name' "${VCN_NAME:-oci-usage-reports}")"
      [[ -z "$vcn_name" ]] && { warn "VCN name cannot be empty."; continue; }

      existing_vcn_id="$(
        run_oci network vcn list \
          --compartment-id "$compartment_id" \
          --all \
          --query "data[?\"display-name\"=='${vcn_name}'].id | [0]" \
          --raw-output 2>/dev/null || true
      )"
      if [[ -z "$existing_vcn_id" || "$existing_vcn_id" == "null" ]]; then
        break
      fi
      warn "A VCN with name '${vcn_name}' already exists in compartment '${compartment_name}'."
      if ! confirm "Enter a different VCN name? (n = go back to create/select choice)" "y"; then
        break
      fi
    done
    [[ -n "$existing_vcn_id" && "$existing_vcn_id" != "null" ]] && continue

    subnet_name="$(prompt_default 'Enter private subnet name' "${SUBNET_NAME:-oci-usage-reports-private}")"
    vcn_cidr="$(prompt_default 'Enter VCN CIDR block' "${VCN_CIDR:-10.0.0.0/16}")"
    subnet_cidr="$(prompt_default 'Enter private subnet CIDR block' "${SUBNET_CIDR:-10.0.1.0/24}")"

    info "Creating VCN '${vcn_name}' in compartment '${compartment_name}'..."
    vcn_id="$(
      run_oci network vcn create \
        --compartment-id "$compartment_id" \
        --display-name "$vcn_name" \
        --cidr-block "$vcn_cidr" \
        --query 'data.id' \
        --raw-output 2>/dev/null
    )"
    if [[ -z "$vcn_id" || "$vcn_id" == "null" ]]; then
      error "Failed to create VCN '${vcn_name}'."
    fi

    # Service Gateway + route so the private subnet can reach OCI services (e.g. OCIR to pull images).
    info "Adding Service Gateway and route for Oracle Services Network (required for OCIR image pull)..."
    local region_key svc_id svc_cidr sgw_id rt_id oci_err svc_name
    region_key="$(detect_default_region || true)"
    # First service is typically "All <region> services in Oracle Services Network"; use its id and CIDR label.
    # Route table API expects a slug like "all-fra-services-in-oracle-services-network". CLI cidr_block can return
    # invalid data (e.g. JSON array); we always derive from service name and use that if API value looks wrong.
    svc_id="$(run_oci_region "$region_key" network service list --all --query 'data[0].id' --raw-output 2>/dev/null || true)"
    svc_name="$(run_oci_region "$region_key" network service list --all --query 'data[0].name' --raw-output 2>/dev/null || true)"
    # Derived label: "All FRA Services In Oracle Services Network" -> all-fra-services-in-oracle-services-network
    local name_derived_cidr
    if [[ -n "$svc_name" && "$svc_name" != "null" ]]; then
      name_derived_cidr="$(echo "$svc_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -d '\n')"
    else
      name_derived_cidr=""
    fi

    svc_cidr="$(run_oci_region "$region_key" network service list --all --query 'data[0].cidr_block' --raw-output 2>/dev/null || true)"
    svc_cidr="$(printf '%s' "$svc_cidr" | tr -d '\n')"
    # Reject API value if it looks like JSON or is not a single slug (route table expects e.g. all-fra-services-in-oracle-services-network)
    if [[ -z "$svc_cidr" || "$svc_cidr" == "null" || "$svc_cidr" =~ [\[\]\"\\] || "$svc_cidr" =~ [[:space:]] ]]; then
      svc_cidr="$name_derived_cidr"
    fi
    if [[ -z "$svc_cidr" ]]; then
      svc_cidr="$(run_oci_region "$region_key" network service list --all --query 'data[0].cidrBlock' --raw-output 2>/dev/null || true)"
      svc_cidr="$(printf '%s' "$svc_cidr" | tr -d '\n')"
      if [[ -z "$svc_cidr" || "$svc_cidr" == "null" || "$svc_cidr" =~ [\[\]\"\\] || "$svc_cidr" =~ [[:space:]] ]]; then
        svc_cidr="$name_derived_cidr"
      fi
    fi
    if [[ -n "$svc_id" && "$svc_id" != "null" && -n "$svc_cidr" && "$svc_cidr" != "null" ]]; then
      oci_err="$(mktemp)"
      sgw_id="$(
        run_oci network service-gateway create \
          --compartment-id "$compartment_id" \
          --vcn-id "$vcn_id" \
          --services "[{\"serviceId\":\"${svc_id}\"}]" \
          --query 'data.id' \
          --raw-output 2>"$oci_err" || true
      )"
      if [[ -z "$sgw_id" || "$sgw_id" == "null" ]]; then
        warn "Could not create Service Gateway; subnet may not reach OCIR."
        [[ -s "$oci_err" ]] && { echo "[OCI CLI error]:"; cat "$oci_err" >&2; }
        rm -f "$oci_err"
        error "Aborting: Service Gateway creation failed. Please fix networking and rerun the installer (or choose an existing private subnet)."
      fi

      # Pass route rules via file so OCI CLI receives valid JSON (avoids shell/quoting issues).
      local route_rules_file
      route_rules_file="$(mktemp)"
      printf '[{"destinationType":"SERVICE_CIDR_BLOCK","destination":"%s","networkEntityId":"%s"}]' "$svc_cidr" "$sgw_id" > "$route_rules_file"

      rt_id="$(
        run_oci network route-table create \
          --compartment-id "$compartment_id" \
          --vcn-id "$vcn_id" \
          --display-name "${vcn_name}-private-rt" \
          --route-rules "file://${route_rules_file}" \
          --query 'data.id' \
          --raw-output 2>"$oci_err" || true
      )"
      rm -f "$route_rules_file"
      if [[ -z "$rt_id" || "$rt_id" == "null" ]]; then
        warn "Could not create route table for Service Gateway; subnet may not reach OCIR."
        [[ -s "$oci_err" ]] && { echo "[OCI CLI error]:"; cat "$oci_err" >&2; }
        rm -f "$oci_err"
        error "Aborting: route table for Service Gateway was not created. Please fix networking and rerun the installer (or choose an existing private subnet)."
      fi

      rm -f "$oci_err"
    else
      warn "Could not resolve Oracle Services Network service for region; subnet may not reach OCIR."
      [[ -z "$svc_id" || "$svc_id" == "null" ]] && warn "Run: oci network service list --all --region <your-region> (check region and OCI permissions)."
      error "Aborting: could not determine Oracle Services Network service for this region. Please fix networking and rerun the installer (or choose an existing private subnet)."
    fi

    info "Creating private subnet '${subnet_name}' in VCN '${vcn_name}'..."
    if [[ -z "$rt_id" || "$rt_id" == "null" ]]; then
      error "Aborting: no route table associated with Service Gateway. Private subnet would not reach OCIR."
    fi

    subnet_id="$(
      run_oci network subnet create \
        --compartment-id "$compartment_id" \
        --vcn-id "$vcn_id" \
        --display-name "$subnet_name" \
        --cidr-block "$subnet_cidr" \
        --prohibit-public-ip-on-vnic true \
        --route-table-id "$rt_id" \
        --query 'data.id' \
        --raw-output 2>/dev/null
    )"
    if [[ -z "$subnet_id" || "$subnet_id" == "null" ]]; then
      error "Failed to create private subnet '${subnet_name}'."
    fi
    break
  done

  desc="App for OCI usage reports functions"

  # Build JSON array for subnet-ids
  local subnet_json
  subnet_json='["'"$subnet_id"'"]'

  info "Running OCI CLI to create application (shape: ${shape})..."
  FN_APP_ID="$(
    run_oci fn application create \
      --compartment-id "$compartment_id" \
      --display-name "$app_name" \
      --subnet-ids "$subnet_json" \
      --shape "$shape" \
      --config '{}' \
      --wait-for-state ACTIVE \
      --max-wait-seconds 600 \
      ${desc:+--freeform-tags "{\"description\":\"$desc\"}"} \
      --query 'data.id' \
      --raw-output 2>/dev/null || true
  )"

  if [[ -z "$FN_APP_ID" || "$FN_APP_ID" == "null" ]]; then
    error "Failed to create OCI Functions application '${app_name}'."
  fi

  info "OCI Functions application '${app_name}' created (${shape}), OCID: ${FN_APP_ID}."
}

print_par_cloud_ui_instructions() {
  echo
  info "Cloud UI steps to create PAR for cross-tenancy upload:"
  echo "  1) In OCI Console, go to Object Storage → Buckets and open the target bucket."
  echo "  2) Click \"Pre-Authenticated Requests\" in the left menu."
  echo "  3) Click \"Create Pre-Authenticated Request\"."
  echo "  4) Set \"Request target\" to \"Bucket\" (not Object)."
  echo "  5) Set \"Access type\" to \"Permit object writes to bucket\"."
  echo "  6) Do NOT set a prefix (leave it empty) so PAR applies to the whole bucket."
  echo "  7) Set an expiry time as needed (for testing you can use 1 year)."
  echo "  8) Click \"Create Pre-Authenticated Request\" and copy the generated URL."
  echo "  9) Use that URL as the value for the x-tenancy_par config on copyusagereport:"
  echo "     fn config function <app-name> copyusagereport x-tenancy_par \"<par_url>\""
  echo
}

ocir_docker_login() {
  # Docker login to OCIR (localhost only). Optional 3rd arg: auth token default. 4th arg "no_prompt_username" = use CLI config username without prompting.
  # Username format: namespace/domain/username
  local region_key="$1"
  local namespace="$2"
  local default_token="${3:-}"
  local no_prompt_username="${4:-}"
  local host="${region_key}.ocir.io"
  local user user_raw token suggested_user domain_choice domain_segment prefix
  local tenancy_ocid domains_array i n custom_opt
  local user_ocid default_user_login
  local container_cmd="${CONTAINER_CMD:-docker}"

  info "OCIR login host: ${host}"

  # On localhost with no_prompt_username: use oracleidentitycloudservice and CLI config user only (no domain/username prompts).
  if [[ "$no_prompt_username" == "no_prompt_username" ]]; then
    domain_segment="oracleidentitycloudservice"
    user_ocid="$(detect_default_user_ocid || true)"
    if [[ -n "$user_ocid" ]] && command -v oci >/dev/null 2>&1; then
      default_user_login="$(
        run_oci iam user get \
          --user-id "$user_ocid" \
          --query 'data.name' \
          --raw-output 2>/dev/null || true
      )"
      [[ "$default_user_login" == */* ]] && default_user_login="${default_user_login##*/}"
    fi
    if [[ -z "${default_user_login:-}" ]]; then
      error "Could not detect OCIR username from OCI CLI config. Set up OCI CLI with a user (e.g. oci setup config) and ensure the profile has a valid user OCID."
    fi
    user_raw="$default_user_login"
    prefix="${namespace}/$(printf '%s' "$domain_segment" | tr '[:upper:]' '[:lower:]')"
    user="${prefix}/${user_raw}"
    info "Using OCIR username from CLI config (no prompt)."
  else
    warn "OCIR username format: \"namespace/domain/username\""
    tenancy_ocid="$(detect_tenancy_ocid || true)"
    domains_array=()
    while IFS= read -r line; do
      line="$(printf '%s' "$line" | tr -d '[:space:]')"
      [[ -z "$line" ]] && continue
      [[ "$line" == "[]" || "$line" == "null" ]] && continue
      domains_array+=("$line")
    done < <(list_identity_domain_names "${tenancy_ocid}" "${region_key}" 2>/dev/null || true)

    if [[ ${#domains_array[@]} -gt 0 ]]; then
      info "Select identity domain for OCIR username (from tenancy root compartment or custom):"
      n=0
      for i in "${domains_array[@]}"; do
        [[ -z "$i" ]] && continue
        n=$((n + 1))
        echo "  ${n}) ${i}"
      done
      custom_opt=$((n + 1))
      echo "  ${custom_opt}) Custom domain"
      while true; do
        domain_choice="$(prompt_default 'Enter choice' '1')"
        if [[ "$domain_choice" == "$custom_opt" ]] || [[ "$domain_choice" == "custom" ]] || [[ "$domain_choice" == "Custom" ]]; then
          domain_segment="$(prompt_default 'Enter custom identity domain segment (e.g. mydomain)' 'oracleidentitycloudservice')"
          break
        fi
        if [[ "$domain_choice" =~ ^[0-9]+$ ]] && [[ "$domain_choice" -ge 1 ]] && [[ "$domain_choice" -le "$n" ]]; then
          domain_segment="${domains_array[$((domain_choice - 1))]}"
          break
        fi
        warn "Invalid choice. Enter 1-${n} for a domain or ${custom_opt} for custom."
      done
    else
      info "Select identity domain for OCIR username:"
      echo "  1) oracleidentitycloudservice (default for IDCS-backed tenancies)"
      echo "  2) Custom domain"
      domain_choice="$(prompt_default 'Enter choice' '1')"
      case "$domain_choice" in
        1|"")
          domain_segment="oracleidentitycloudservice"
          ;;
        2)
          domain_segment="$(prompt_default 'Enter custom identity domain segment (e.g. mydomain)' 'oracleidentitycloudservice')"
          ;;
        *)
          warn "Unknown choice '${domain_choice}', defaulting to 'oracleidentitycloudservice'."
          domain_segment="oracleidentitycloudservice"
          ;;
      esac
    fi

    domain_segment_lower="$(printf '%s' "$domain_segment" | tr '[:upper:]' '[:lower:]')"
    prefix="${namespace}/${domain_segment_lower}"
    user_ocid="$(detect_default_user_ocid || true)"
    if [[ -n "$user_ocid" ]] && command -v oci >/dev/null 2>&1; then
      default_user_login="$(
        run_oci iam user get \
          --user-id "$user_ocid" \
          --query 'data.name' \
          --raw-output 2>/dev/null || true
      )"
      [[ "$default_user_login" == */* ]] && default_user_login="${default_user_login##*/}"
    fi
  fi

  for attempt in 1 2 3; do
    if [[ "$no_prompt_username" != "no_prompt_username" ]]; then
      user_raw="$(prompt_default "Enter OCIR username (user part only)" "${default_user_login:-}")"
      if [[ -z "$user_raw" ]]; then
        warn "Username cannot be empty."
        continue
      fi
      user="${prefix}/${user_raw}"
    fi

    if [[ -n "$default_token" ]]; then
      token="$default_token"
      info "Using the auth token just generated."
      warn "If login fails, wait 1–2 minutes for the new token to propagate and try again."
      default_token=""
    else
      read -s -p "Enter OCIR auth token (will not be echoed): " token || true
      echo
    fi
    if [[ -z "$token" ]]; then
      warn "Auth token cannot be empty."
      continue
    fi

    info "Testing ${container_cmd} login to ${host} with username '${user}' (attempt ${attempt}/3)..."
    while true; do
      if printf '%s' "$token" | "${container_cmd}" login "$host" -u "$user" --password-stdin; then
        info "${container_cmd} login to OCIR succeeded."
        return 0
      fi
      warn "${container_cmd} login failed. Token propagation may take a minute for new tokens."
      if ! confirm "Retry in 60 seconds? (token propagation)" "y"; then
        break
      fi
      info "Waiting 60 seconds before retry..."
      sleep 60
    done
  done

  error "Could not log in to OCIR after 3 attempts."
}

prechecks() {
  info "Running prechecks for required CLIs"
  check_cmd oci
  check_cmd jq
  if [[ "${INSTALLER_ENV:-}" == "cloud_shell" ]]; then
    check_cmd podman
    info "All required CLIs are available: oci, jq, podman"
  else
    check_cmd docker
    info "All required CLIs are available: oci, jq, docker"
  fi
}

# OCIR login: Cloud Shell uses auth tokens (username + domain selection + token creation), localhost uses raw-request token.
ocir_login() {
  local region_key="$1"
  local namespace="${2:-}"
  
  if [[ "${INSTALLER_ENV:-}" == "cloud_shell" ]]; then
    ocir_login_cloud_shell "${region_key}" "${namespace}"
  else
    ocir_login_localhost "${region_key}"
  fi
}

ocir_login_cloud_shell() {
  local region_key="$1"
  local namespace="$2"
  local host="${region_key}.ocir.io"
  local user_ocid domain_segment domain_segment_lower user_raw user prefix token desc tenancy_ocid domains_array i n custom_opt domain_choice default_user_login
  
  info "OCIR login for Cloud Shell (using auth token)"
  
  # Get namespace if not provided (should be available from install_prebuilt_with_fn)
  if [[ -z "$namespace" ]]; then
    namespace="$(detect_default_namespace || true)"
    [[ -z "$namespace" ]] && namespace="$(oci os ns get --query 'data' --raw-output 2>/dev/null || true)"
    [[ -z "$namespace" ]] && error "Could not determine Object Storage namespace for OCIR login."
  fi
  
  # Ask if user wants to login to OCIR (default yes)
  if ! confirm "Login to OCIR with temporary auth token?" "y"; then
    info "Skipping OCIR login. Will rely on existing docker login in Cloud Shell."
    return 0
  fi
  
  # Get tenancy OCID once (needed for domain listing and user lookup)
  tenancy_ocid="$(detect_tenancy_ocid || true)"
  [[ -z "$tenancy_ocid" ]] && error "Could not detect tenancy OCID."
  
  # Retry loop: prompt for username and domain, then lookup user OCID
  while true; do
    # 1) Prompt for username (default from .env: OCIR_USER)
    user_raw="$(prompt_default 'Enter OCIR username (user part only)' "${OCIR_USER:-}")"
    [[ -z "$user_raw" ]] && error "OCIR username is required."
    
    # 2) Show identity domains in tenancy root to select
    domains_array=()
    while IFS= read -r line; do
      line="$(printf '%s' "$line" | tr -d '[:space:]')"
      [[ -z "$line" ]] && continue
      [[ "$line" == "[]" || "$line" == "null" ]] && continue
      domains_array+=("$line")
    done < <(list_identity_domain_names "${tenancy_ocid}" "${region_key}" 2>/dev/null || true)
    
    if [[ ${#domains_array[@]} -gt 0 ]]; then
      info "Select identity domain for OCIR username (from tenancy root compartment or custom):"
      n=0
      for i in "${domains_array[@]}"; do
        [[ -z "$i" ]] && continue
        n=$((n + 1))
        echo "  ${n}) ${i}"
      done
      custom_opt=$((n + 1))
      echo "  ${custom_opt}) Custom domain"
      while true; do
        domain_choice="$(prompt_default 'Enter choice' '1')"
        if [[ "$domain_choice" == "$custom_opt" ]] || [[ "$domain_choice" == "custom" ]] || [[ "$domain_choice" == "Custom" ]]; then
          domain_segment="$(prompt_default 'Enter custom identity domain segment (e.g. mydomain)' 'oracleidentitycloudservice')"
          break
        fi
        if [[ "$domain_choice" =~ ^[0-9]+$ ]] && [[ "$domain_choice" -ge 1 ]] && [[ "$domain_choice" -le "$n" ]]; then
          domain_segment="${domains_array[$((domain_choice - 1))]}"
          break
        fi
        warn "Invalid choice. Enter 1-${n} for a domain or ${custom_opt} for custom."
      done
    else
      info "Select identity domain for OCIR username:"
      echo "  1) oracleidentitycloudservice (default for IDCS-backed tenancies)"
      echo "  2) Custom domain"
      domain_choice="$(prompt_default 'Enter choice' '1')"
      case "$domain_choice" in
        1|"")
          domain_segment="oracleidentitycloudservice"
          ;;
        2)
          domain_segment="$(prompt_default 'Enter custom identity domain segment (e.g. mydomain)' 'oracleidentitycloudservice')"
          ;;
        *)
          warn "Unknown choice '${domain_choice}', defaulting to 'oracleidentitycloudservice'."
          domain_segment="oracleidentitycloudservice"
          ;;
      esac
    fi
    
    domain_segment_lower="$(printf '%s' "$domain_segment" | tr '[:upper:]' '[:lower:]')"
    prefix="${namespace}/${domain_segment_lower}"
    user="${prefix}/${user_raw}"
    
    # 3) Try to find user OCID
    user_ocid="$(detect_default_user_ocid || true)"
    if [[ -z "$user_ocid" ]]; then
      # Try to find user OCID by username (for Cloud Shell where CLI config may not have user OCID)
      info "Looking up user OCID by username '${user_raw}' in tenancy..."
      # Search in tenancy root compartment
      # Try domain/username format first (most common)
      user_ocid="$(oci iam user list --compartment-id "$tenancy_ocid" --all --name "${domain_segment_lower}/${user_raw}" --query 'data[0].id' --raw-output 2>/dev/null || true)"
      if [[ -z "$user_ocid" || "$user_ocid" == "null" ]]; then
        # Try just username
        user_ocid="$(oci iam user list --compartment-id "$tenancy_ocid" --all --name "${user_raw}" --query 'data[0].id' --raw-output 2>/dev/null || true)"
      fi
      if [[ -z "$user_ocid" || "$user_ocid" == "null" ]]; then
        # Try query filter for exact match
        user_ocid="$(oci iam user list --compartment-id "$tenancy_ocid" --all --query "data[?name=='${domain_segment_lower}/${user_raw}'].id | [0]" --raw-output 2>/dev/null || true)"
        if [[ -z "$user_ocid" || "$user_ocid" == "null" ]]; then
          user_ocid="$(oci iam user list --compartment-id "$tenancy_ocid" --all --query "data[?name=='${user_raw}'].id | [0]" --raw-output 2>/dev/null || true)"
        fi
      fi
    fi
    
    if [[ -n "$user_ocid" && "$user_ocid" != "null" ]]; then
      info "Found user OCID: ${user_ocid}"
      break
    fi
    
    # User OCID not found - ask to retry
    warn "Could not find user OCID. Tried: CLI config, username '${user_raw}', and '${domain_segment_lower}/${user_raw}'."
    if ! confirm "Enter a different username and try again?" "y"; then
      error "Could not detect user OCID. Provide USER_OCID in .env or ensure the username exists in the tenancy."
    fi
  done
  
  desc="oci-usage-reports-ocir-token-temp"
  
  # Check if token was already created (for retry scenarios) - reuse if same user
  local token_create_output token_id token_value token_just_created=false
  if [[ -n "${OCIR_AUTH_TOKEN_VALUE:-}" && -n "${OCIR_AUTH_TOKEN_USER:-}" && "$user" == "${OCIR_AUTH_TOKEN_USER}" ]]; then
    info "Reusing existing OCIR auth token (token already created for this user)..."
    token_value="${OCIR_AUTH_TOKEN_VALUE}"
    token_id="${OCIR_AUTH_TOKEN_ID:-}"
    # Still need user_ocid for cleanup
    if [[ -z "${OCIR_AUTH_TOKEN_USER_OCID:-}" ]]; then
      OCIR_AUTH_TOKEN_USER_OCID="$user_ocid"
    fi
  else
    info "Creating temporary OCIR auth token via OCI CLI to user's profile..."
    token_create_output="$(oci iam auth-token create \
        --user-id "$user_ocid" \
        --description "$desc" \
        --output json 2>/dev/null || true)"
    
    if [[ -z "$token_create_output" ]]; then
      error "Failed to create auth token via OCI CLI. Check your permissions and try manually from the OCI Console."
    fi
    
    token_value="$(echo "$token_create_output" | jq -r '.data.token // empty' 2>/dev/null || true)"
    token_id="$(echo "$token_create_output" | jq -r '.data.id // empty' 2>/dev/null || true)"
    
    if [[ -z "$token_value" || -z "$token_id" ]]; then
      error "Failed to create auth token via OCI CLI. Check your permissions and try manually from the OCI Console."
    fi
    
    # Store token ID, value, user OCID, and username globally so token can be reused or deleted after push
    OCIR_AUTH_TOKEN_ID="$token_id"
    OCIR_AUTH_TOKEN_USER_OCID="$user_ocid"
    OCIR_AUTH_TOKEN_VALUE="$token_value"
    OCIR_AUTH_TOKEN_USER="$user"
    token_just_created=true
  fi
  
  # 4) Wait 60 seconds for token propagation (only if token was just created, not reused)
  if [[ "$token_just_created" == "true" ]]; then
    info "Waiting 60 seconds for token propagation..."
    sleep 60
  else
    info "Reusing existing token; skipping propagation wait."
  fi
  
  # 5) Login to OCIR with format: namespace/domain/username and auth token (try initially, then retry up to 2 more times)
  local attempt
  for attempt in 1 2 3; do
    info "Logging in to OCIR (${host}) with username '${user}' (attempt ${attempt}/3)..."
    if "${CONTAINER_CMD}" login "$host" -u "$user" -p "$token_value" 2>/dev/null; then
      info "${CONTAINER_CMD} login to OCIR succeeded."
      # Store token value for use in push retry
      token="$token_value"
      return 0
    fi
    if [[ $attempt -lt 3 ]]; then
      warn "Login failed (attempt ${attempt}/3). Token may need more time to propagate. Retrying in 10 seconds..."
      sleep 10
    fi
  done
  
  # After max retries, try manual login fallback
  warn "${CONTAINER_CMD} login to OCIR failed after 3 attempts. Trying manual login fallback..."
  local manual_user manual_token
  manual_user="$(prompt_default 'Enter OCIR username (format: namespace/domain/username)' "${OCIR_AUTH_TOKEN_USER:-$user}")"
  [[ -z "$manual_user" ]] && error "OCIR username is required."
  read -s -p "Enter OCIR auth token (will not be echoed): " manual_token || true
  echo
  [[ -z "$manual_token" ]] && error "OCIR auth token is required."
  
  info "Logging in to OCIR (${host}) with manual credentials..."
  if "${CONTAINER_CMD}" login "$host" -u "$manual_user" -p "$manual_token" 2>/dev/null; then
    info "${CONTAINER_CMD} login to OCIR succeeded with manual credentials."
    # Store manual token for use in push
    token="$manual_token"
    OCIR_AUTH_TOKEN_USER="$manual_user"
    return 0
  else
    error "${CONTAINER_CMD} login to OCIR failed with manual credentials. Check username and token."
  fi
}

ocir_login_localhost() {
  local region_key="$1"
  local host="${region_key}.ocir.io"
  local token
  info "Logging in to OCIR (${host}) via oci raw-request token..."
  token="$(run_oci raw-request --region "$region_key" --http-method GET \
      --target-uri "https://${region_key}.ocir.io/20180419/docker/token" \
      2>/dev/null | jq -r .data.token)" || true
  if [[ -z "$token" || "$token" == "null" ]]; then
    error "Failed to get OCIR token. Ensure OCI CLI is configured."
  fi
  if printf '%s' "$token" | "${CONTAINER_CMD}" login -u BEARER_TOKEN --password-stdin "$host"; then
    info "${CONTAINER_CMD} login to OCIR succeeded."
    return 0
  fi
  error "${CONTAINER_CMD} login to OCIR failed."
}

prompt_default() {
  local prompt="$1"
  local default="${2:-}"
  local value
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " value || true
    echo "${value:-$default}"
  else
    read -r -p "$prompt: " value || true
    echo "$value"
  fi
}

confirm() {
  local prompt="$1"
  local default="${2:-y}"
  local answer
  # Show options [Y/n] or [y/N] so default is clear (brackets avoid any subshell parsing of parentheses)
  local label
  case "$default" in
    [Yy]*) label="Y/n" ;;
    *)     label="y/N" ;;
  esac

  read -r -p "${prompt} [${label}]: " answer || true
  answer="${answer:-$default}"
  case "$answer" in
    [Yy]*) return 0 ;;
    *)     return 1 ;;
  esac
}

install_prebuilt_with_fn() {
  local region_key namespace repo_name app_name bucket_name secret par_url tenancy_ocid days arch arch_tag
  par_url=""
  local default_region default_namespace
  default_region="$(detect_default_region || true)"
  default_namespace="$(detect_default_namespace || true)"

  # Use podman in Cloud Shell (instance-principal OCIR login), docker on localhost.
  if [[ "${INSTALLER_ENV:-}" == "cloud_shell" ]]; then
    CONTAINER_CMD=podman
  else
    CONTAINER_CMD=docker
  fi

  region_key="$(prompt_default 'Enter OCI region key' "${default_region:-}")"
  [[ -z "$region_key" ]] && error "Region key is required."

  namespace="$(prompt_default 'Enter OCIR namespace' "${default_namespace:-}")"
  [[ -z "$namespace" ]] && error "OCIR namespace is required."

  repo_name="$(prompt_default 'Enter OCIR repository name' "${OCIR_REPO_NAME:-oci-usage-reports}")"

  # Architecture selection for prebuilt images (needed before creating the Functions application for shape).
  info "Select the architecture that matches your local system."
  while true; do
    arch="$(prompt_default 'Select architecture for prebuilt images (x86/arm)' "${ARCH:-x86}")"
    # Normalize to lower-case without relying on bash-specific ${var,,}
    arch_normalized="$(printf '%s' "$arch" | tr '[:upper:]' '[:lower:]')"
    case "$arch_normalized" in
      x86|amd64)
        arch_tag="x86"
        break
        ;;
      arm|arm64)
        arch_tag="arm"
        break
        ;;
      *)
        warn "Invalid architecture. Please enter 'x86' or 'arm'."
        ;;
    esac
  done

  # Create the Functions application (prompts for compartment, then app name, then VCN/subnet; shape matches selected arch).
  create_functions_application "${arch_tag}"
  if [[ -z "$FN_APP_ID" ]]; then
    error "Internal error: Functions application OCID not set after creation."
  fi

  # Bucket name is prompted later: when no secret, or when secret with PAR option 1 (or for target bucket when secret).

  # tenancy_ocid is no longer prompted; leave empty to rely on function config defaults.
  tenancy_ocid=""
  days="$(prompt_default 'Optional: days lookback for reports (default 3)' '3')"

  local registry="${region_key}.ocir.io/${namespace}/${repo_name}"

  # Create OCIR container repositories in the Functions app compartment (not tenancy root) so the function can pull images.
  # Image paths are namespace/repo_name/oci-copy-usage-report and namespace/repo_name/oci-xtenancy-check; create both repo paths.
  local app_compartment_id app_compartment_name existing_repo repo_path
  app_compartment_id="$(run_oci fn application get --application-id "$FN_APP_ID" --query 'data."compartment-id"' --raw-output 2>/dev/null || true)"
  app_compartment_name=""
  if [[ -n "$app_compartment_id" && "$app_compartment_id" != "null" ]]; then
    app_compartment_name="$(run_oci iam compartment get --compartment-id "$app_compartment_id" --query 'data.name' --raw-output 2>/dev/null || true)"
  fi
  if [[ -n "$app_compartment_id" && "$app_compartment_id" != "null" ]]; then
    for repo_path in "${repo_name}/oci-copy-usage-report" "${repo_name}/oci-xtenancy-check"; do
      info "Ensuring OCIR repository '${repo_path}' exists in compartment '${app_compartment_name:-$app_compartment_id}'..."
      existing_repo="$(run_oci artifacts container repository list \
        --compartment-id "$app_compartment_id" \
        --display-name "$repo_path" \
        --query 'data[0].id' --raw-output 2>/dev/null || true)"
      if [[ -z "$existing_repo" || "$existing_repo" == "null" ]]; then
        local create_out
        create_out="$(run_oci artifacts container repository create \
          --compartment-id "$app_compartment_id" \
          --display-name "$repo_path" \
          --query 'data.id' --raw-output 2>&1)" || true
        if [[ "$create_out" =~ ^ocid1\. ]]; then
          info "OCIR repository '${repo_path}' created in compartment '${app_compartment_name:-$app_compartment_id}'."
        elif [[ "$create_out" == *"Repository already exists"* || "$create_out" == *"NAMESPACE_CONFLICT"* ]]; then
          info "OCIR repository '${repo_path}' already exists (reusing existing)."
        else
          [[ -n "$create_out" ]] && echo "$create_out" >&2
          warn "Could not create OCIR repository '${repo_path}' in compartment '${app_compartment_name:-$app_compartment_id}' (check permissions). Push may create it in tenancy root; if function fails to pull (502), create the repository in the app compartment and re-push."
        fi
      else
        info "OCIR repository '${repo_path}' already exists in compartment '${app_compartment_name:-$app_compartment_id}' (reusing existing)."
      fi
    done
  else
    warn "Could not get Functions app compartment; OCIR repositories may be created in tenancy root on first push."
  fi

  ocir_login "${region_key}" "${namespace}"

  info "Pulling prebuilt images from Docker Hub (${arch_tag})"
  "${CONTAINER_CMD}" pull "mikarinneoracle/oci-copy-usage-report:${arch_tag}"
  "${CONTAINER_CMD}" pull "mikarinneoracle/oci-xtenancy-check:${arch_tag}"

  info "Tagging images for OCIR: ${registry} (${arch_tag})"
  "${CONTAINER_CMD}" tag "mikarinneoracle/oci-copy-usage-report:${arch_tag}" "${registry}/oci-copy-usage-report:${arch_tag}"
  "${CONTAINER_CMD}" tag "mikarinneoracle/oci-xtenancy-check:${arch_tag}" "${registry}/oci-xtenancy-check:${arch_tag}"

  info "Pushing images to OCIR (${arch_tag})"
  push_ocir_with_retry() {
    local img="$1"
    local push_out tmp
    tmp="$(mktemp)"
    if "${CONTAINER_CMD}" push "$img" 2>&1 | tee "$tmp"; then
      rm -f "$tmp"
      return 0
    fi
    push_out="$(cat "$tmp")"
    rm -f "$tmp"
    if [[ "$push_out" == *[Uu]nauthorized* || "$push_out" == *"invalid username/password"* || "$push_out" == *"StatusCode: 403"* || "$push_out" == *"403"* ]]; then
      warn "Push failed (auth/403); re-authenticating and retrying..."
      ocir_login "${region_key}" "${namespace}" || { echo "$push_out" >&2; return 1; }
      sleep 5
      info "Retrying push: $img"
      if "${CONTAINER_CMD}" push "$img" 2>&1 | tee "$tmp"; then
        rm -f "$tmp"
        return 0
      fi
      push_out="$(cat "$tmp")"
      rm -f "$tmp"
      echo "$push_out" >&2
      if [[ "$push_out" == *"StatusCode: 403"* || "$push_out" == *"403"* ]]; then
        local comp_info=""
        if [[ -n "$app_compartment_name" ]]; then
          comp_info=" in compartment '${app_compartment_name}'"
        elif [[ -n "$app_compartment_id" ]]; then
          comp_info=" in compartment '${app_compartment_id}'"
        fi
        warn "Push still failing with 403. Ensure the instance principal (Cloud Shell) or user has 'manage repos' permission on the OCIR repositories${comp_info}. Check IAM policies for the Functions app compartment."
      fi
      return 1
    else
      echo "$push_out" >&2
      return 1
    fi
  }
  
  # Try pushing with automatic token
  local copy_push_failed=false xten_push_failed=false
  if ! push_ocir_with_retry "${registry}/oci-copy-usage-report:${arch_tag}"; then
    copy_push_failed=true
  fi
  if ! push_ocir_with_retry "${registry}/oci-xtenancy-check:${arch_tag}"; then
    xten_push_failed=true
  fi
  
  # Fallback: if push failed and we're in Cloud Shell, ask for manual username/token
  if [[ ("$copy_push_failed" == "true" || "$xten_push_failed" == "true") && "${INSTALLER_ENV:-}" == "cloud_shell" ]]; then
    warn "Push failed after retries. Trying fallback: manual username and token."
    local manual_user manual_token host="${region_key}.ocir.io"
    # Extract username part from OCIR_AUTH_TOKEN_USER if available (format: namespace/domain/username)
    local default_username="${OCIR_AUTH_TOKEN_USER:-}"
    manual_user="$(prompt_default 'Enter OCIR username (format: namespace/domain/username)' "$default_username")"
    [[ -z "$manual_user" ]] && error "OCIR username is required."
    read -s -p "Enter OCIR auth token (will not be echoed): " manual_token || true
    echo
    [[ -z "$manual_token" ]] && error "OCIR auth token is required."
    
    info "Logging in to OCIR (${host}) with manual credentials..."
    if "${CONTAINER_CMD}" login "$host" -u "$manual_user" -p "$manual_token" 2>/dev/null; then
      info "${CONTAINER_CMD} login to OCIR succeeded with manual credentials."
      info "Retrying push with manual credentials..."
      if [[ "$copy_push_failed" == "true" ]]; then
        if ! "${CONTAINER_CMD}" push "${registry}/oci-copy-usage-report:${arch_tag}" 2>&1; then
          error "Failed to push oci-copy-usage-report image with manual credentials."
        fi
        info "oci-copy-usage-report pushed successfully."
      fi
      if [[ "$xten_push_failed" == "true" ]]; then
        if ! "${CONTAINER_CMD}" push "${registry}/oci-xtenancy-check:${arch_tag}" 2>&1; then
          error "Failed to push oci-xtenancy-check image with manual credentials."
        fi
        info "oci-xtenancy-check pushed successfully."
      fi
      info "Push succeeded with manual credentials."
    else
      error "${CONTAINER_CMD} login to OCIR failed with manual credentials. Check username and token."
    fi
  elif [[ "$copy_push_failed" == "true" || "$xten_push_failed" == "true" ]]; then
    error "Push failed after retries. Check your OCIR permissions and try again."
  fi

  # Delete the temporary auth token after successful push (Cloud Shell only)
  if [[ "${INSTALLER_ENV:-}" == "cloud_shell" && -n "${OCIR_AUTH_TOKEN_ID:-}" && -n "${OCIR_AUTH_TOKEN_USER_OCID:-}" ]]; then
    info "Deleting temporary OCIR auth token..."
    if oci iam auth-token delete --user-id "$OCIR_AUTH_TOKEN_USER_OCID" --auth-token-id "$OCIR_AUTH_TOKEN_ID" --force 2>/dev/null; then
      info "Temporary OCIR auth token deleted."
    else
      warn "Failed to delete temporary OCIR auth token. Please delete it manually from the OCI Console."
    fi
    unset OCIR_AUTH_TOKEN_ID
    unset OCIR_AUTH_TOKEN_USER_OCID
    unset OCIR_AUTH_TOKEN_VALUE
    unset OCIR_AUTH_TOKEN_USER
  fi

  # Secret and PAR: no secret → prompt target bucket only. With secret → show PAR options first; option 1 prompts bucket for PAR, sets bucket_name, and we ensure bucket exists; option 2 uses existing PAR, bucket_name from .env default, skip bucket creation.
  secret="$(prompt_default 'Enter secret (leave empty to skip xtenancycheck deployment and just to use a local bucket for the reports)' "")"
  secret="$(printf '%s' "$secret" | tr -d '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  local skip_bucket_ensure=false
  if [[ -z "$secret" ]]; then
    bucket_name="$(prompt_default 'Enter target bucket name for copyusagereport' "${BUCKET_NAME:-copyusagereport}")"
    [[ -z "$bucket_name" ]] && bucket_name="copyusagereport"
  fi
  if [[ -n "$secret" ]]; then
    echo
    info "PAR for cross-tenancy upload (copyusagereport will use this to write to the other tenancy's bucket):"
    echo "  1) Create a new PAR with bucket for cross-tenancy upload and add it to copyusagereport config"
    echo "  2) Use existing PAR (enter URL) and add it to copyusagereport config"
    local par_choice par_days ns_par par_expiry par_name access_uri par_bucket
    par_choice="$(prompt_default 'Enter choice (1/2)' '1')"
    case "$(printf '%s' "$par_choice" | tr '[:upper:]' '[:lower:]')" in
      1)
        par_bucket="$(prompt_default 'Enter bucket name for PAR' "${BUCKET_NAME:-copyusagereport}")"
        [[ -z "$par_bucket" ]] && par_bucket="copyusagereport"
        bucket_name="$par_bucket"
        par_days="$(prompt_default 'Enter PAR validity in days' "${PAR_TTL_DAYS:-365}")"
        par_days="$((par_days + 0))"
        [[ "$par_days" -lt 1 ]] && par_days=365
        
        # Ensure bucket exists before creating PAR
        local app_compartment_id ns_par
        app_compartment_id="$(run_oci fn application get --application-id "$FN_APP_ID" --query 'data."compartment-id"' --raw-output 2>/dev/null || true)"
        ns_par="$(detect_default_namespace || true)"
        [[ -z "$ns_par" ]] && ns_par="$(run_oci os ns get --query 'data' --raw-output 2>/dev/null || true)"
        
        if [[ -z "$ns_par" ]]; then
          warn "Could not determine Object Storage namespace; skipping bucket check and PAR creation."
        elif [[ -z "$app_compartment_id" || "$app_compartment_id" == "null" ]]; then
          warn "Could not get Functions app compartment; skipping bucket check. Ensure bucket '${par_bucket}' exists before creating PAR."
        else
          # Check if bucket exists, create if not
          if ! run_oci os bucket get --namespace-name "$ns_par" --name "$par_bucket" >/dev/null 2>&1; then
            info "Creating Object Storage bucket '${par_bucket}' in namespace '${ns_par}' (compartment of the Functions application)..."
            if ! run_oci os bucket create \
              --namespace-name "$ns_par" \
              --compartment-id "$app_compartment_id" \
              --name "$par_bucket" \
              --query 'data.id' --raw-output >/dev/null 2>&1; then
              warn "Could not create bucket '${par_bucket}'. Ensure it exists before creating PAR."
            else
              info "Bucket '${par_bucket}' created."
            fi
          else
            info "Bucket '${par_bucket}' already exists in namespace '${ns_par}'."
          fi
          
          # Create PAR after ensuring bucket exists
          info "Creating bucket-level PAR for cross-tenancy uploads (AnyObjectWrite)..."
          par_expiry="$(python3 -c "from datetime import datetime, timedelta, timezone; print((datetime.now(timezone.utc) + timedelta(days=$par_days)).isoformat(timespec='seconds').replace('+00:00','Z'))")"
          par_name="copyusagereport-par-$(date +%Y%m%d%H%M%S)"
          access_uri="$(
            run_oci os preauth-request create \
              --namespace-name "$ns_par" \
              --bucket-name "$par_bucket" \
              --name "$par_name" \
              --access-type AnyObjectWrite \
              --time-expires "$par_expiry" \
              --query 'data."access-uri"' \
              --raw-output 2>/dev/null || true
          )"
          if [[ -n "$access_uri" && "$access_uri" != "null" ]]; then
            par_url="https://objectstorage.${region_key}.oraclecloud.com${access_uri}"
            info "PAR created for bucket '${par_bucket}' (namespace '${ns_par}'). Expires: ${par_expiry}"
            echo "PAR URL (share with the other tenancy): ${par_url}"
          else
            warn "Failed to create PAR via OCI CLI. Ensure bucket '${par_bucket}' exists and you have permissions. Create it in OCI Console or use option 2 with an existing PAR."
          fi
        fi
        ;;
      2)
        par_url="$(prompt_default 'Enter existing PAR URL for cross-tenancy upload' "")"
        if [[ -z "$par_url" ]]; then
          warn "No PAR URL entered."
        fi
        bucket_name="${BUCKET_NAME:-copyusagereport}"
        [[ -z "$bucket_name" ]] && bucket_name="copyusagereport"
        skip_bucket_ensure=true
        ;;
    esac
  fi

  # Ensure the target Object Storage bucket exists (function will fail with BucketNotFound otherwise). Skip when option 2 (existing PAR) was chosen.
  if [[ "$skip_bucket_ensure" != "true" ]]; then
    local app_compartment_id ns
    app_compartment_id="$(run_oci fn application get --application-id "$FN_APP_ID" --query 'data."compartment-id"' --raw-output 2>/dev/null || true)"
    ns="$(detect_default_namespace || true)"
    [[ -z "$ns" ]] && ns="$(run_oci os ns get --query 'data' --raw-output 2>/dev/null || true)"
    if [[ -n "$app_compartment_id" && -n "$ns" ]]; then
      if ! run_oci os bucket get --namespace-name "$ns" --name "$bucket_name" >/dev/null 2>&1; then
        info "Creating Object Storage bucket '${bucket_name}' in namespace '${ns}' (compartment of the Functions application)..."
        if run_oci os bucket create \
          --namespace-name "$ns" \
          --compartment-id "$app_compartment_id" \
          --name "$bucket_name" \
          --query 'data.id' --raw-output >/dev/null 2>&1; then
          info "Bucket '${bucket_name}' created."
        else
          warn "Could not create bucket '${bucket_name}'. Ensure it exists and the Functions dynamic group has access, or the copyusagereport function will fail with BucketNotFound."
        fi
      else
        info "Bucket '${bucket_name}' already exists in namespace '${ns}'."
      fi
    else
      warn "Could not resolve compartment or namespace; skipping bucket check. Ensure bucket '${bucket_name}' exists or copyusagereport will fail with BucketNotFound."
    fi
  else
    info "Using existing PAR; skipping bucket creation. Ensure bucket '${bucket_name}' exists in this tenancy for copyusagereport."
  fi

  # Build config for copyusagereport function (includes PAR if set earlier).
  local copy_cfg
  copy_cfg="{\"bucket_name\":\"${bucket_name}\",\"days\":\"${days}\""
  if [[ -n "$tenancy_ocid" ]]; then
    copy_cfg+=",\"tenancy_ocid\":\"${tenancy_ocid}\""
  fi
  if [[ -n "$secret" ]]; then
    copy_cfg+=",\"secret\":\"${secret}\""
  fi
  if [[ -n "$par_url" ]]; then
    copy_cfg+=",\"x-tenancy_par\":\"${par_url}\""
  fi
  copy_cfg+="}"

  info "Creating copyusagereport function with prebuilt image (${arch_tag}) via OCI CLI"
  FN_COPY_ID="$(
    run_oci fn function create \
      --application-id "$FN_APP_ID" \
      --display-name copyusagereport \
      --image "${registry}/oci-copy-usage-report:${arch_tag}" \
      --memory-in-mbs 256 \
      --config "$copy_cfg" \
      --query 'data.id' \
      --raw-output 2>/dev/null || true
  )"
  if [[ -z "$FN_COPY_ID" || "$FN_COPY_ID" == "null" ]]; then
    error "Failed to create copyusagereport function."
  fi
  info "copyusagereport function created (OCID: ${FN_COPY_ID})."

  if [[ -n "$secret" ]]; then
    if confirm "Deploy xtenancycheck with prebuilt image (requires same secret)?"; then
      # Build config for xtenancycheck function
      local xt_cfg
      xt_cfg="{\"secret\":\"${secret}\"}"

      info "Creating xtenancycheck function with prebuilt image (${arch_tag}) via OCI CLI"
      FN_XTEN_ID="$(
        run_oci fn function create \
          --application-id "$FN_APP_ID" \
          --display-name xtenancycheck \
          --image "${registry}/oci-xtenancy-check:${arch_tag}" \
          --memory-in-mbs 256 \
          --config "$xt_cfg" \
          --query 'data.id' \
          --raw-output 2>/dev/null || true
      )"
      if [[ -z "$FN_XTEN_ID" || "$FN_XTEN_ID" == "null" ]]; then
        error "Failed to create xtenancycheck function."
      fi
      info "xtenancycheck function created (OCID: ${FN_XTEN_ID})."
    else
      warn "Skipping xtenancycheck deployment."
    fi
  else
    warn "Secret is empty; xtenancycheck will not be deployed or validated."
  fi

  # Optional post-deploy test
  if confirm "Run a quick test of the deployed functions now?" "y"; then
    local test_choice
    if [[ -n "$FN_XTEN_ID" && "$FN_XTEN_ID" != "null" ]]; then
      info "Select which functions to test:"
      echo "  1) copyusagereport only"
      echo "  2) xtenancycheck only"
      echo "  3) both"
      test_choice="$(prompt_default 'Enter choice' '3')"
    else
      info "xtenancycheck was not deployed (no secret or deployment skipped); only copyusagereport can be tested."
      test_choice="1"
    fi

    local test_copy="no" test_xten="no"
    case "$test_choice" in
      1) test_copy="yes" ;;
      2) test_xten="yes" ;;
      3) test_copy="yes"; test_xten="yes" ;;
      *) test_copy="yes" ;; # default to copyusagereport
    esac

    if [[ "$test_copy" == "yes" && -n "$FN_COPY_ID" && "$FN_COPY_ID" != "null" ]]; then
      info "Invoking copyusagereport via OCI CLI for a quick smoke test..."
      local invoke_out
      invoke_out="$(mktemp)"
      if run_oci fn function invoke \
        --function-id "$FN_COPY_ID" \
        --body '{}' \
        --file "$invoke_out" \
        2>/dev/null; then
        info "Function response:"
        sed 's/^/  /' "$invoke_out"
        if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(1 if d.get('error') else 0)" "$invoke_out" 2>/dev/null; then
          info "copyusagereport test invocation succeeded (JSON response without error)."
        else
          warn "copyusagereport returned JSON with an error or invalid response. Check the output above and function logs in OCI Console."
        fi
      else
        warn "copyusagereport test invocation failed (CLI or function error). Check function logs in OCI Console."
        [[ -s "$invoke_out" ]] && { info "Response body:"; sed 's/^/  /' "$invoke_out"; }
      fi
      rm -f "$invoke_out"
    fi

    if [[ "$test_xten" == "yes" && -n "$FN_XTEN_ID" && "$FN_XTEN_ID" != "null" && -n "$secret" ]]; then
      info "Running xtenancycheck test: uploading and then deleting a test object with secret prefix..."
      local ns test_obj tmpfile secret_b64
      ns="$(detect_default_namespace || true)"
      if [[ -z "$ns" ]]; then
        if command -v oci >/dev/null 2>&1; then
          ns="$(run_oci os ns get --query 'data' --raw-output 2>/dev/null || true)"
        fi
      fi
      if [[ -z "$ns" ]]; then
        warn "Could not determine Object Storage namespace; skipping xtenancycheck test."
      else
        secret_b64="$(printf '%s' "$secret" | base64)"
        test_obj="${secret_b64}_xtenancycheck_test_$(date +%s)_$RANDOM.txt"
        tmpfile="$(mktemp "${TMPDIR:-/tmp}/xtenancycheck_test.XXXXXX")"
        printf 'xtenancycheck test\n' >"$tmpfile"

        info "Uploading test object '${test_obj}' to bucket '${bucket_name}' (namespace '${ns}')..."
        if run_oci os object put \
          --bucket-name "$bucket_name" \
          --namespace "$ns" \
          --name "$test_obj" \
          --file "$tmpfile" \
          --force \
          >/dev/null 2>&1; then
          info "Test object uploaded. Waiting briefly to allow any event processing..."
          sleep 5
          info "Deleting test object '${test_obj}' from bucket '${bucket_name}'..."
          run_oci os object delete \
            --bucket-name "$bucket_name" \
            --namespace "$ns" \
            --object-name "$test_obj" \
            --force \
            >/dev/null 2>&1 || warn "Failed to delete test object '${test_obj}'. Please delete it manually if needed."
          info "xtenancycheck test completed (object created and cleaned up)."
        else
          warn "Failed to upload test object; skipping xtenancycheck test."
        fi

        rm -f "$tmpfile"
      fi
    fi
  fi

  info "Prebuilt install completed."
}

main() {
  info "Deploy prebuilt usage-report functions to OCI."
  info "This will:"
  info "  - Pull prebuilt Docker images for copyusagereport (and optionally xtenancycheck)."
  info "  - Push those images to your OCIR repository."
  info "  - Create (or reuse) an OCI Functions application."
  info "  - Create and configure the copyusagereport function."
  info "  - Optionally create and configure the xtenancycheck function for cross-tenancy checks."

  # Choose execution environment: Cloud Shell, localhost, or quit.
  info "Select where to run the installer:"
  info "  1) OCI Cloud Shell (recommended)"
  info "  2) Localhost (this machine)"
  info "  3) Quit"

  while true; do
    choice="$(prompt_default 'Enter choice' "${INSTALLER_CHOICE:-1}")"
    case "$choice" in
      1|"")
        INSTALLER_ENV=cloud_shell
        info "Using OCI Cloud Shell; skipping CLI config setup (default config will be used)."
        if confirm "Free space with 'docker system prune -a' before continuing? (removes unused images, containers, networks)" "n"; then
          docker system prune -a || true
        fi
        prechecks
        # Leave OCI_CLI_CONFIG_PATH and OCI_CLI_PROFILE_NAME unset so oci/fn use environment defaults.
        break
        ;;
      "2")
        INSTALLER_ENV=localhost
        info "Using localhost; configuring OCI CLI config path and profile."
        prechecks
        setup_oci_cli_context
        break
        ;;
      "3")
        info "Exiting without changes."
        exit 0
        ;;
      *)
        warn "Invalid choice. Please enter 1, 2, or 3."
        ;;
    esac
  done

  install_prebuilt_with_fn
}

main "$@"
