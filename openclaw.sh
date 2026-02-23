#!/usr/bin/env bash
set -euo pipefail

# ===========================================================
# OpenClaw Agent Deployment for Targon
# Usage: curl -fsSL https://targon.com/openclaw.sh | bash
# ===========================================================

BOLD='\033[1m'
INFO='\033[38;2;136;146;176m'
SUCCESS='\033[38;2;0;229;204m'
WARN='\033[38;2;255;176;32m'
ERROR='\033[38;2;230;57;70m'
MUTED='\033[38;2;90;100;128m'
ACCENT='\033[38;2;255;77;77m'
NC='\033[0m'

print_banner() {
	echo -e "${ACCENT}"
	cat <<'BANNER'
┌──────────────────────────────────────────┐
│░▀█▀░█▀█░█▀▄░█▀▀░█▀█░█▀█░░░█▀▀░█░░░█▀█░█░█│
│░░█░░█▀█░█▀▄░█░█░█░█░█░█░░░█░░░█░░░█▀█░█▄█│
│░░▀░░▀░▀░▀░▀░▀▀▀░▀▀▀░▀░▀░░░▀▀▀░▀▀▀░▀░▀░▀░▀│
└──────────────────────────────────────────┘
BANNER
  	echo -e "${NC}"
}

log_info()    { echo -e "${INFO}  →${NC} $*"; }
log_success() { echo -e "${SUCCESS}  ✓${NC} $*"; }
log_warn()    { echo -e "${WARN}  ⚠${NC} $*" >&2; }
log_error()   { echo -e "${ERROR}  ✗${NC} $*" >&2; }
log_section() { echo -e "\n${BOLD}${INFO}$*${NC}\n"; }
log_muted()   { echo -e "${MUTED}$*${NC}"; }
TARGON_DEPLOY_URL="${TARGON_DEPLOY_URL:-https://api.targon.com/v1/deployments}"

die() {
  log_error "$*"
  exit 1
}

check_deps() {
	log_section "Checking dependencies"
	local missing=()
	for cmd in curl jq; do
		if command -v "$cmd" &>/dev/null; then
			log_success "$cmd found"
		else
			log_error "$cmd not found"
			missing+=("$cmd")
		fi
	done
	if command -v openssl &>/dev/null; then
		log_success "openssl found (used for token generation)"
	else
		log_warn "openssl not found — will fall back to /dev/urandom for token generation"
	fi

	if [ "${#missing[@]}" -gt 0 ]; then
		die "Missing required tools: ${missing[*]}. Please install them and re-run."
	fi
}

generate_token() {
	if command -v openssl &>/dev/null; then
		openssl rand -hex 32
	elif [ -r /dev/urandom ]; then
		head -c 32 /dev/urandom | od -A n -t x1 | tr -d ' \n'
	else
		date +%s%N | sha256sum | head -c 64
	fi
}

# Read interactive user input from terminal when script stdin is piped.
# Usage: read_user_input VAR_NAME [secret]
read_user_input() {
  local var_name="$1"
  local secret="${2:-}"

  if [ -r /dev/tty ]; then
    if [ "$secret" = "secret" ]; then
      IFS= read -rs "$var_name" </dev/tty
      echo >/dev/tty
    else
      IFS= read -r "$var_name" </dev/tty
    fi
  else
    if [ "$secret" = "secret" ]; then
      IFS= read -rs "$var_name"
      echo
    else
      IFS= read -r "$var_name"
    fi
  fi
}

# Prompt for a required value (re-asks until non-empty).
# Usage: prompt_required VAR_NAME "Prompt text" [secret]
prompt_required() {
  local var_name="$1"
  local prompt_text="$2"
  local secret="${3:-}"
  local value=""

  while [ -z "$value" ]; do
    if [ "$secret" = "secret" ]; then
      echo -en "${BOLD}${prompt_text}:${NC} "
      read_user_input value secret
    else
      echo -en "${BOLD}${prompt_text}:${NC} "
      read_user_input value
    fi
    if [ -z "$value" ]; then
      log_error "This field is required. Please enter a value."
    fi
  done
  printf -v "$var_name" '%s' "$value"
}

# Prompt for an optional value (returns empty string if skipped).
# Usage: prompt_optional VAR_NAME "Prompt text" "default value" [secret]
prompt_optional() {
  local var_name="$1"
  local prompt_text="$2"
  local default_val="${3:-}"
  local secret="${4:-}"
  local value=""

  if [ -n "$default_val" ]; then
    echo -en "${BOLD}${prompt_text}${NC} ${MUTED}[${default_val}]${NC}: "
  else
    echo -en "${BOLD}${prompt_text}${NC} ${MUTED}[leave blank to auto-generate]${NC}: "
  fi

  if [ "$secret" = "secret" ]; then
    read_user_input value secret
  else
    read_user_input value
  fi

  if [ -z "$value" ] && [ -n "$default_val" ]; then
    value="$default_val"
  fi
  printf -v "$var_name" '%s' "$value"
}

prompt_confirm() {
  local var_name="$1"
  local prompt_text="$2"
  local value=""
  while true; do
    echo -en "${BOLD}${prompt_text}${NC} ${MUTED}[y/N]${NC}: "
    read_user_input value
    case "$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" in
      y|yes) printf -v "$var_name" 'yes'; return 0 ;;
      n|no|"") printf -v "$var_name" 'no'; return 0 ;;
      *) log_error "Please answer y or n." ;;
    esac
  done
}

# Validate deployment name: lowercase alphanumeric and hyphens, max 63 chars.
validate_deploy_name() {
  local name="$1"
  if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]{0,61}[a-z0-9]$|^[a-z0-9]$ ]]; then
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Provider → model defaults
# ---------------------------------------------------------------------------
default_model_for_provider() {
  case "$1" in
    openai)    echo "openai/gpt-4o" ;;
    anthropic) echo "anthropic/claude-sonnet-4-20250514" ;;
    google)    echo "google/gemini-2.0-flash" ;;
    sybill)    echo "zai-org/GLM-4.6" ;;
    *)         echo "" ;;
  esac
}

provider_env_key() {
  case "$1" in
    openai)    echo "OPENAI_API_KEY" ;;
    anthropic) echo "ANTHROPIC_API_KEY" ;;
    google)    echo "GOOGLE_API_KEY" ;;
    sybill)    echo "SYBILL_API_KEY" ;;
    *)         echo "" ;;
  esac
}

provider_display_name() {
  case "$1" in
    openai)    echo "OpenAI" ;;
    anthropic) echo "Anthropic" ;;
    google)    echo "Google" ;;
    sybill)    echo "Sybill" ;;
    *)         echo "$1" ;;
  esac
}

# ---------------------------------------------------------------------------
# Build JSON env array
# ---------------------------------------------------------------------------
build_env_json() {
  local provider="$1"
  local provider_key_name="$2"
  local provider_key_value="$3"
  local default_model="$4"
  local gateway_token="$5"
  local gateway_port="$6"
  local channel="$7"
  local channel_token="${8:-}"
  local disable_device_auth="${9:-false}"

  # Start with the base env array
  local env_arr='[]'

  # Provider env vars
  if [ -n "$provider_key_name" ] && [ -n "$provider_key_value" ]; then
    env_arr=$(echo "$env_arr" | jq \
      --arg pkn "$provider_key_name" \
      --arg pkv "$provider_key_value" \
      '. + [{"name": $pkn, "value": $pkv}]')
  fi

  if [ -n "$provider" ]; then
    env_arr=$(echo "$env_arr" | jq \
      --arg provider "$provider" \
      '. + [{"name": "OPENCLAW_DEFAULT_PROVIDER", "value": $provider}]')
  fi

  if [ -n "$default_model" ]; then
    env_arr=$(echo "$env_arr" | jq \
      --arg model "$default_model" \
      '. + [{"name": "OPENCLAW_DEFAULT_MODEL", "value": $model}]')
  fi

  # Gateway token + port + device auth behavior
  env_arr=$(echo "$env_arr" | jq \
    --arg token "$gateway_token" \
    --arg port "$gateway_port" \
    --arg disable_device_auth "$disable_device_auth" \
    '. + [
      {"name": "OPENCLAW_GATEWAY_TOKEN",       "value": $token},
      {"name": "OPENCLAW_GATEWAY_PORT",        "value": $port},
      {"name": "DISABLE_DEVICE_AUTH",          "value": $disable_device_auth}
    ]')

  # Channel + channel token
  if [ -n "$channel" ] && [ "$channel" != "skip" ]; then
    env_arr=$(echo "$env_arr" | jq \
      --arg ch "$channel" \
      '. + [{"name": "OPENCLAW_CHANNEL", "value": $ch}]')
    if [ -n "$channel_token" ]; then
      env_arr=$(echo "$env_arr" | jq \
        --arg t "$channel_token" \
        '. + [{"name": "OPENCLAW_CHANNEL_TOKEN", "value": $t}]')
    fi
  fi

  echo "$env_arr"
}

build_payload() {
  local deploy_name="$1"
  local env_json="$2"
  local port="$3"
  local resource_name="$4"

  jq -n \
    --arg name "$deploy_name" \
    --argjson env "$env_json" \
    --argjson port "$port" \
    --arg rn "$resource_name" \
    '{
      "name": $name,
      "image": "ghcr.io/manifold-inc/openclaw/openclaw:latest",
      "resource_name": $rn,
      "env": $env,
      "ports": [{
        "port": $port,
        "protocol": "TCP",
        "routingType": "Proxy"
      }]
    }'
}

deploy() {
	local targon_token="$1"
	local payload="$2"

	log_info "Sending deploy request to Targon..."

	local body_file http_code body
	body_file="$(mktemp)"

	if ! http_code="$(curl -sS \
		--connect-timeout 10 \
		--max-time 60 \
		-o "$body_file" \
		-w "%{http_code}" \
		-X POST "${TARGON_DEPLOY_URL}" \
		-H "Authorization: Bearer ${targon_token}" \
		-H "Content-Type: application/json" \
		-d "$payload")"; then
		rm -f "$body_file"
		die "Network error while calling Targon deploy API."
	fi

	body="$(<"$body_file")"
	rm -f "$body_file"

	DEPLOY_HTTP_CODE="$http_code"
	DEPLOY_BODY="$body"
}

fetch_deployment_status() {
	local targon_token="$1"
	local deployment_uid="$2"
	local status_url="${TARGON_DEPLOY_URL%/}/${deployment_uid}"
	local body_file http_code body
	body_file="$(mktemp)"

	if ! http_code="$(curl -sS \
		--connect-timeout 10 \
		--max-time 60 \
		-o "$body_file" \
		-w "%{http_code}" \
		-X GET "${status_url}" \
		-H "Authorization: Bearer ${targon_token}" \
		-H "Content-Type: application/json")"; then
		rm -f "$body_file"
		log_warn "Could not fetch deployment status from Targon."
		return 1
	fi

	body="$(<"$body_file")"
	rm -f "$body_file"

	if [[ "$http_code" != 2* ]]; then
		log_warn "Status API returned HTTP ${http_code}; skipping URL print."
		return 1
	fi

	STATUS_BODY="$body"
	return 0
}

print_result() {
  local body="$1"
  local gateway_token="$2"
  local targon_token="$3"

  local uid name namespace capacity_warning error_msg

  uid=$(echo "$body"             | jq -r '.DeploymentUID // .deployment_uid // ""')
  name=$(echo "$body"            | jq -r '.Name // .name // ""')
  namespace=$(echo "$body"       | jq -r '.Namespace // .namespace // ""')
  capacity_warning=$(echo "$body"| jq -r '.CapacityWarning // .capacity_warning // ""')
  error_msg=$(echo "$body"       | jq -r '.Error // .error // ""')

  # Surface any API-level error
  if [ -n "$error_msg" ] && [ "$error_msg" != "null" ]; then
    die "Deployment error from Targon: $error_msg"
  fi

  echo
  echo -e "${SUCCESS}${BOLD}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${SUCCESS}${BOLD}  OpenClaw deployed successfully on Targon!${NC}"
  echo -e "${SUCCESS}${BOLD}╚══════════════════════════════════════════════╝${NC}"
  echo

  [ -n "$uid"       ] && log_success "Deployment ID : ${BOLD}$uid${NC}"
  [ -n "$name"      ] && log_success "Name          : ${BOLD}$name${NC}"
  [ -n "$namespace" ] && log_success "Namespace     : ${BOLD}$namespace${NC}"

  if [ -n "$uid" ]; then
    log_success "Dashboard URL : ${BOLD}https://targon.com/rentals/$uid${NC}"
  fi
  sleep 2
  # Query deployment status to print runtime DNS URLs.
  if [ -n "$uid" ] && fetch_deployment_status "$targon_token" "$uid"; then
    local dns_urls
    dns_urls="$(echo "${STATUS_BODY}" | jq -r '
      (
        .PortToDNSMapping // .portToDNSMapping // .port_to_dns_mapping // {}
      ) as $m
      | if ($m | type) == "object" then
          [ $m | to_entries[] | .value ]
        else
          []
        end
      | map(select(. != null and (. | tostring | length > 0)))
      | map(if (test("^https?://")) then . else ("https://" + .) end)
      | unique
      | .[]
    ' 2>/dev/null || true)"

    if [ -n "$dns_urls" ]; then
      echo
      log_success "ClawBot URL(s):"
      while IFS= read -r url; do
        [ -n "$url" ] && echo -e "  ${BOLD}${url}${NC}"
      done <<< "$dns_urls"
    else
      log_muted "Deployment created, but URL is not ready yet (PortToDNSMapping empty)."
    fi
  fi

  echo
  log_warn "Save your Gateway Token — you will need it to connect agents:"
  echo -e "  ${BOLD}${ACCENT}$gateway_token${NC}"

  if [ -n "$capacity_warning" ] && [ "$capacity_warning" != "null" ]; then
    echo
    log_warn "Capacity notice: $capacity_warning"
  fi

  echo
  log_muted "It may take a minute for the gateway to become reachable."
}

main() {
	print_banner

	echo -e "${BOLD}Welcome to the OpenClaw installer for Targon.${NC}"
	log_muted "This will deploy OpenClaw to Targon's cloud and return your dashboard URL."
	echo

	check_deps

	# ----- Targon credentials -----------------------------------------------
	log_section "Targon Account"
	prompt_required TARGON_API_KEY "Targon API Key" secret

	# ----- Deployment name ---------------------------------------------------
	log_section "Deployment"
	local DEPLOY_NAME=""
	while true; do
	prompt_required DEPLOY_NAME "Deployment name (lowercase, hyphens allowed)"
	if validate_deploy_name "$DEPLOY_NAME"; then
		break
	else
		log_error "Invalid name. Use lowercase letters, numbers and hyphens (e.g. my-openclaw). Must start/end with alphanumeric."
		DEPLOY_NAME=""
	fi
	done

	# ----- Resource Size ------------------------------------------------------
	log_section "Resource Size"
	echo -e "  ${MUTED}1)${NC} cpu-small"
	echo -e "  ${MUTED}2)${NC} cpu-medium"
	echo -e "  ${MUTED}3)${NC} cpu-large"
	echo -e "  ${MUTED}4)${NC} cpu-xlarge"
	echo

	local RESOURCE_CHOICE="" RESOURCE_NAME=""
	while true; do
	echo -en "${BOLD}Choose resource size [1/2/3/4]:${NC} "
	read_user_input RESOURCE_CHOICE
	case "$RESOURCE_CHOICE" in
		1|"") RESOURCE_NAME="cpu-small";  break ;;
		2) RESOURCE_NAME="cpu-medium"; break ;;
		3) RESOURCE_NAME="cpu-large";  break ;;
		4) RESOURCE_NAME="cpu-xlarge"; break ;;
		*) log_error "Please enter 1, 2, 3, or 4." ;;
	esac
	done
	log_info "Resource: ${BOLD}$RESOURCE_NAME${NC}"

	# ----- AI Provider -------------------------------------------------------
	log_section "Model / Auth Provider"
	echo -e "  ${MUTED}1)${NC} OpenAI"
	echo -e "  ${MUTED}2)${NC} Anthropic"
	echo -e "  ${MUTED}3)${NC} Google"
	echo -e "  ${MUTED}4)${NC} Sybill"
	echo -e "  ${MUTED}5)${NC} Skip for now"
	echo

	local PROVIDER_CHOICE="" PROVIDER=""
	local PROVIDER_KEY_NAME="" PROVIDER_API_KEY="" DEFAULT_MODEL=""
	while true; do
	echo -en "${BOLD}Choose provider [1/2/3/4/5]:${NC} "
	read_user_input PROVIDER_CHOICE
	case "$PROVIDER_CHOICE" in
		1) PROVIDER="openai";    break ;;
		2) PROVIDER="anthropic"; break ;;
		3) PROVIDER="google";    break ;;
		4) PROVIDER="sybill";    break ;;
		5) PROVIDER="skip";      break ;;
		*) log_error "Please enter 1, 2, 3, 4, or 5." ;;
	esac
	done

	local DISPLAY_NAME
	local MODEL_DEFAULT
	if [ "$PROVIDER" = "skip" ]; then
		DISPLAY_NAME="skip"
		DEFAULT_MODEL="skip"
		log_warn "Skipping provider setup for now — configure API provider later."
	else
		DISPLAY_NAME="$(provider_display_name "$PROVIDER")"
		log_info "Selected: ${BOLD}$DISPLAY_NAME${NC}"

		# API key
		PROVIDER_KEY_NAME="$(provider_env_key "$PROVIDER")"
		prompt_required PROVIDER_API_KEY "Enter ${DISPLAY_NAME} API key" secret

		# Default model (editable, pre-filled with sensible default)
		MODEL_DEFAULT="$(default_model_for_provider "$PROVIDER")"
		prompt_optional DEFAULT_MODEL "Default model name" "$MODEL_DEFAULT"
		log_info "Model: ${BOLD}$DEFAULT_MODEL${NC}"
	fi

	# Sybill-specific: API base URL for the custom OpenAI-compatible endpoint
	local SYBILL_BASE_URL=""
	if [ "$PROVIDER" = "sybill" ]; then
		prompt_optional SYBILL_BASE_URL "Sybill API base URL" "https://api.sybil.com/v1"
		log_info "Base URL: ${BOLD}$SYBILL_BASE_URL${NC}"
	fi

	# ----- Channel (QuickStart) -----------------------------------------------
	log_section "Select Channel (QuickStart)"
	echo -e "  ${MUTED}1)${NC} Telegram (Bot API)"
	echo -e "  ${MUTED}2)${NC} WhatsApp (QR link)"
	echo -e "  ${MUTED}3)${NC} Discord (Bot API)"
	echo -e "  ${MUTED}4)${NC} Skip for now"
	echo

	local CHANNEL_CHOICE="" CHANNEL=""
	local CHANNEL_TOKEN="" CHANNEL_ALLOW_FROM=""
	while true; do
	echo -en "${BOLD}Choose channel [1/2/3/4]:${NC} "
	read_user_input CHANNEL_CHOICE
	case "$CHANNEL_CHOICE" in
		1) CHANNEL="telegram"; break ;;
		2) CHANNEL="whatsapp"; break ;;
		3) CHANNEL="discord";  break ;;
		4) CHANNEL="skip";     break ;;
		*) log_error "Please enter 1, 2, 3, or 4." ;;
	esac
	done

	case "$CHANNEL" in
	telegram)
		log_info "Selected: ${BOLD}Telegram${NC}"
		prompt_required CHANNEL_TOKEN "Telegram Bot Token" secret
		prompt_optional CHANNEL_ALLOW_FROM "Telegram allowFrom (comma-separated, e.g. tg:123,tg:456)" ""
		;;
	whatsapp)
		log_info "Selected: ${BOLD}WhatsApp${NC}"
		log_muted "WhatsApp uses QR-based linking. The QR code will appear in the gateway logs after deploy."
		prompt_optional CHANNEL_ALLOW_FROM "WhatsApp allowFrom (comma-separated, e.g. +15550001,+44770002)" ""
		;;
	discord)
		log_info "Selected: ${BOLD}Discord${NC}"
		prompt_required CHANNEL_TOKEN "Discord Bot Token" secret
		prompt_optional CHANNEL_ALLOW_FROM "Discord allowFrom (comma-separated IDs/usernames)" ""
		;;
	skip)
		log_warn "Skipping channel setup — you can configure channels later via the dashboard."
		;;
	esac

	# ----- Gateway Port ------------------------------------------------------
	log_section "Gateway Port"
	local GATEWAY_PORT=""
	prompt_optional GATEWAY_PORT "Gateway port" "18789"
	if ! [[ "$GATEWAY_PORT" =~ ^[0-9]+$ ]] || [ "$GATEWAY_PORT" -lt 1 ] || [ "$GATEWAY_PORT" -gt 65535 ]; then
		die "Invalid port number: $GATEWAY_PORT (must be 1-65535)"
	fi
	log_info "Gateway port: ${BOLD}$GATEWAY_PORT${NC}"

	# ----- Gateway Token -----------------------------------------------------
	log_section "Gateway Token"
	log_muted "The gateway token secures communication between your agents and OpenClaw."

	local GATEWAY_TOKEN=""
	prompt_optional GATEWAY_TOKEN "Gateway token" "" secret

	if [ -z "$GATEWAY_TOKEN" ]; then
	GATEWAY_TOKEN="$(generate_token)"
	log_warn "Auto-generated gateway token (save this, required for login):"
	echo -e "  ${BOLD}${ACCENT}${GATEWAY_TOKEN}${NC}"
	else
	log_info "Using provided gateway token."
	fi

	# ----- Device Auth -------------------------------------------------------
	log_section "Device Pairing / Auth"
	log_muted "If disabled, users can access without manual SSH pairing approval."
	local DISABLE_DEVICE_AUTH_CHOICE=""
	local DISABLE_DEVICE_AUTH="true"
	while true; do
		echo -en "${BOLD}Disable device auth and skip pairing requests?${NC} ${MUTED}[Y/n]${NC}: "
		read_user_input DISABLE_DEVICE_AUTH_CHOICE
		case "$(printf '%s' "$DISABLE_DEVICE_AUTH_CHOICE" | tr '[:upper:]' '[:lower:]')" in
			""|y|yes)
				DISABLE_DEVICE_AUTH="true"
				log_warn "Device auth disabled."
				break
				;;
			n|no)
				DISABLE_DEVICE_AUTH="false"
				log_info "Device auth enabled (manual approval required)."
				break
				;;
			*)
				log_error "Please answer y or n."
				;;
		esac
	done

	# ----- Review ------------------------------------------------------------
	log_section "Review"
	log_muted "Deployment name: $DEPLOY_NAME"
	log_muted "Resource size : $RESOURCE_NAME"
	log_muted "Provider      : $DISPLAY_NAME"
	log_muted "Model         : $DEFAULT_MODEL"
	log_muted "Channel       : ${CHANNEL:-skip}"
	log_muted "Gateway port  : $GATEWAY_PORT"
	log_muted "Device auth   : $([ "$DISABLE_DEVICE_AUTH" = "true" ] && echo "disabled" || echo "enabled (pairing required)")"
	echo

	local CONFIRM_DEPLOY=""
	prompt_confirm CONFIRM_DEPLOY "Proceed with deployment?"
	if [ "$CONFIRM_DEPLOY" != "yes" ]; then
		die "Deployment cancelled by user."
	fi

	# ----- Build & Send ------------------------------------------------------
	log_section "Deploying"

	local ENV_JSON
	ENV_JSON="$(build_env_json \
		"$PROVIDER" \
		"$PROVIDER_KEY_NAME" \
		"$PROVIDER_API_KEY" \
		"$DEFAULT_MODEL" \
		"$GATEWAY_TOKEN" \
		"$GATEWAY_PORT" \
		"${CHANNEL:-skip}" \
		"${CHANNEL_TOKEN:-}" \
		"$DISABLE_DEVICE_AUTH")"

	# Sybill-specific: pass the custom base URL so entrypoint.sh can build
	# the full models.providers section in the config
	if [ "$PROVIDER" = "sybill" ] && [ -n "${SYBILL_BASE_URL:-}" ]; then
		ENV_JSON=$(echo "$ENV_JSON" | jq \
			--arg url "$SYBILL_BASE_URL" \
			'. + [{"name": "SYBILL_BASE_URL", "value": $url}]')
	fi

	# Channel-specific env vars consumed by entrypoint.sh for config patching
	case "${CHANNEL:-skip}" in
	telegram)
		ENV_JSON=$(echo "$ENV_JSON" | jq \
			--arg token "${CHANNEL_TOKEN:-}" \
			'. + [{"name": "TELEGRAM_BOT_TOKEN", "value": $token}]')
		if [ -n "${CHANNEL_ALLOW_FROM:-}" ]; then
			ENV_JSON=$(echo "$ENV_JSON" | jq \
				--arg allow "${CHANNEL_ALLOW_FROM}" \
				'. + [{"name": "OPENCLAW_TELEGRAM_ALLOW_FROM", "value": $allow}]')
		fi
		;;
	discord)
		ENV_JSON=$(echo "$ENV_JSON" | jq \
			--arg token "${CHANNEL_TOKEN:-}" \
			'. + [{"name": "DISCORD_BOT_TOKEN", "value": $token}]')
		if [ -n "${CHANNEL_ALLOW_FROM:-}" ]; then
			ENV_JSON=$(echo "$ENV_JSON" | jq \
				--arg allow "${CHANNEL_ALLOW_FROM}" \
				'. + [{"name": "OPENCLAW_DISCORD_ALLOW_FROM", "value": $allow}]')
		fi
		;;
	whatsapp)
		ENV_JSON=$(echo "$ENV_JSON" | jq \
			'. + [{"name": "OPENCLAW_WHATSAPP_ENABLED", "value": "true"}]')
		if [ -n "${CHANNEL_ALLOW_FROM:-}" ]; then
			ENV_JSON=$(echo "$ENV_JSON" | jq \
				--arg allow "${CHANNEL_ALLOW_FROM}" \
				'. + [{"name": "OPENCLAW_WHATSAPP_ALLOW_FROM", "value": $allow}]')
		fi
		;;
	esac

	local PAYLOAD
	PAYLOAD="$(build_payload "$DEPLOY_NAME" "$ENV_JSON" "$GATEWAY_PORT" "$RESOURCE_NAME")"

	echo

	deploy "$TARGON_API_KEY" "$PAYLOAD"
	local HTTP_CODE="$DEPLOY_HTTP_CODE"
	local BODY="$DEPLOY_BODY"

	# Treat any non-2xx as an error
	if [[ "$HTTP_CODE" != 2* ]]; then
	log_error "Targon API returned HTTP $HTTP_CODE:"
	echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"
	exit 1
	fi

	print_result "$BODY" "$GATEWAY_TOKEN" "$TARGON_API_KEY"
}

main "$@"
