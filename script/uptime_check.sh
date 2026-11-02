#!/usr/bin/env bash
# Checks that the live site is up. Run every 15 minutes by .github/workflows/uptime.yml
# (GitHub emails you when a run fails); also usable by hand:
#
#   script/uptime_check.sh                         # checks https://bowda.edsouthwood.com
#   UPTIME_RESOLVE=127.0.0.1 script/uptime_check.sh  # from the server itself (skips the NAT hairpin)
#
# Each check is retried before it counts as a failure, so a momentary blip doesn't alert.
set -uo pipefail

HOST="${UPTIME_HOST:-bowda.edsouthwood.com}"
BASE="https://${HOST}"
ATTEMPTS="${UPTIME_ATTEMPTS:-3}"
RETRY_DELAY="${UPTIME_RETRY_DELAY:-30}"
MIN_CERT_DAYS="${UPTIME_MIN_CERT_DAYS:-14}"
CURL_OPTS=(--silent --show-error --max-time 30 --location)
CONNECT="${HOST}:443"
if [[ -n "${UPTIME_RESOLVE:-}" ]]; then
  CURL_OPTS+=(--resolve "${HOST}:443:${UPTIME_RESOLVE}")
  CONNECT="${UPTIME_RESOLVE}:443"
fi

failures=()
body_file="$(mktemp)"
err_file="$(mktemp)"
trap 'rm -f "$body_file" "$err_file"' EXIT

# check_page NAME PATH [TEXT]: expects HTTP 200 and, if given, TEXT in the body.
check_page() {
  local name="$1" path="$2" text="${3:-}" status="" problem=""
  for attempt in $(seq 1 "$ATTEMPTS"); do
    status="$(curl "${CURL_OPTS[@]}" -o "$body_file" -w '%{http_code}' "${BASE}${path}" 2>"$err_file")"
    if [[ "$status" == "000" ]]; then
      problem="no response ($(head -c 200 "$err_file" | tr -d '\n'))"
    elif [[ "$status" != "200" ]]; then
      problem="HTTP ${status}"
    elif [[ -n "$text" ]] && ! grep -q "$text" "$body_file"; then
      problem="200 but the page doesn't contain \"${text}\""
    else
      echo "ok   ${name} (${BASE}${path})"
      return 0
    fi
    echo "     ${name}: attempt ${attempt}/${ATTEMPTS} failed: ${problem}"
    [[ "$attempt" -lt "$ATTEMPTS" ]] && sleep "$RETRY_DELAY"
  done
  failures+=("${name}: ${problem} (${BASE}${path})")
}

check_certificate() {
  local end_date end_epoch days
  end_date="$(echo | openssl s_client -connect "$CONNECT" -servername "$HOST" 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
  if [[ -z "$end_date" ]]; then
    failures+=("HTTPS certificate: couldn't read it from ${HOST}")
    return
  fi
  end_epoch="$(date -d "$end_date" +%s)"
  days=$(( (end_epoch - $(date +%s)) / 86400 ))
  if (( days < MIN_CERT_DAYS )); then
    failures+=("HTTPS certificate: expires in ${days} days (${end_date}); Caddy should have renewed it by now")
  else
    echo "ok   HTTPS certificate (${days} days left)"
  fi
}

check_page "Health check" "/up"
check_page "Home page" "/en" "Bouldering on Dartmoor"
check_certificate

if (( ${#failures[@]} > 0 )); then
  echo
  echo "SITE PROBLEM at $(date -u '+%Y-%m-%d %H:%M UTC'):"
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
echo "All checks passed."
