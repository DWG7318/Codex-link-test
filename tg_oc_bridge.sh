#!/usr/bin/env bash
set -u -o pipefail

LOG_FILE="${HOME}/tg_oc_bridge.log"
OFFSET_FILE="${HOME}/.tg_oc_bridge_offset.txt"
LOCK_FILE="${HOME}/.tg_oc_bridge.lock"
POLL_TIMEOUT=25
RETRY_SLEEP=3
SEND_RETRY_SLEEP=2
SEND_RETRY_MAX=5

exec >>"${LOG_FILE}" 2>&1

log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[${ts}] $*"
}

require_env() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    log "FATAL: missing required env var ${name}"
    exit 1
  fi
}

redacted_url() {
  local method="$1"
  echo "https://api.telegram.org/bot<REDACTED>/${method}"
}

build_curl_cmd_preview() {
  local method="$1"
  shift
  local preview="curl -sS --connect-timeout 10 --max-time 40"
  if [ -n "${HTTPS_PROXY:-}" ]; then
    preview+=" -x $(printf '%q' "${HTTPS_PROXY}")"
  fi
  local arg
  for arg in "$@"; do
    preview+=" $(printf '%q' "${arg}")"
  done
  preview+=" $(printf '%q' "$(redacted_url "${method}")")"
  echo "${preview}"
}

require_env "TG_TOKEN"
require_env "TG_CHAT_ID"
if [[ ! "${TG_CHAT_ID}" =~ ^-?[0-9]+$ ]]; then
  log "FATAL: TG_CHAT_ID must be numeric"
  exit 1
fi

exec 200>"${LOCK_FILE}"
if ! flock -n 200; then
  log "WARN: another tg_oc_bridge instance is already running, exit."
  exit 1
fi

if [ ! -f "${OFFSET_FILE}" ]; then
  echo "0" >"${OFFSET_FILE}"
fi

read_offset() {
  local value
  value="$(cat "${OFFSET_FILE}" 2>/dev/null || echo "0")"
  if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
    value="0"
  fi
  echo "${value}"
}

write_offset() {
  local value="$1"
  local tmp_file="${OFFSET_FILE}.tmp"
  echo "${value}" >"${tmp_file}"
  mv -f "${tmp_file}" "${OFFSET_FILE}"
}

tg_api() {
  local method="$1"
  shift

  local -a cmd
  cmd=(curl -sS --connect-timeout 10 --max-time 40)
  if [ -n "${HTTPS_PROXY:-}" ]; then
    cmd+=(-x "${HTTPS_PROXY}")
  fi

  # curl options/data must be before URL
  cmd+=("$@" "https://api.telegram.org/bot${TG_TOKEN}/${method}")
  "${cmd[@]}"
}

send_tg_message() {
  local text="$1"
  local attempt=1
  local resp=""

  while [ ${attempt} -le ${SEND_RETRY_MAX} ]; do
    resp="$(tg_api "sendMessage" \
      --data-urlencode "chat_id=${TG_CHAT_ID}" \
      --data-urlencode "text=${text}" \
      --data-urlencode "allow_sending_without_reply=true")"
    local rc=$?

    if [ ${rc} -eq 0 ] && [ -n "${resp}" ]; then
      if python3 - <<'PY' <<<"${resp}"
import json
import sys

raw = sys.stdin.read().strip()
try:
    data = json.loads(raw)
except Exception:
    sys.exit(1)

if isinstance(data, dict) and data.get("ok") is True:
    sys.exit(0)

sys.exit(1)
PY
      then
        return 0
      fi
    fi

    log "WARN: sendMessage failed attempt=${attempt}/${SEND_RETRY_MAX}, retry in ${SEND_RETRY_SLEEP}s"
    if [ ${rc} -ne 0 ]; then
      log "WARN: sendMessage curl cmd=$(build_curl_cmd_preview "sendMessage" --data-urlencode "chat_id=${TG_CHAT_ID}" --data-urlencode "text=${text}" --data-urlencode "allow_sending_without_reply=true")"
    fi
    sleep "${SEND_RETRY_SLEEP}"
    attempt=$((attempt + 1))
  done

  log "WARN: sendMessage exhausted retries, payload=$(printf '%q' "${text}")"
  return 1
}

extract_updates() {
  python3 - <<'PY'
import base64
import json
import sys

raw = sys.stdin.read().strip()
if not raw:
    print("META\t-1")
    sys.exit(0)

try:
    data = json.loads(raw)
except Exception:
    print("META\t-1")
    sys.exit(0)

result = data.get("result") if isinstance(data, dict) else []
if not isinstance(result, list):
    result = []

max_id = -1
for item in result:
    if isinstance(item, dict):
        uid = item.get("update_id")
        if isinstance(uid, int) and uid > max_id:
            max_id = uid

print(f"META\t{max_id}")

for item in result:
    if not isinstance(item, dict):
        continue
    uid = item.get("update_id")
    msg = item.get("message") or item.get("edited_message")
    if not isinstance(uid, int) or not isinstance(msg, dict):
        continue
    text = msg.get("text")
    if not isinstance(text, str):
        continue
    chat = msg.get("chat") if isinstance(msg.get("chat"), dict) else {}
    sender = msg.get("from") if isinstance(msg.get("from"), dict) else {}
    chat_id = chat.get("id")
    is_bot = bool(sender.get("is_bot", False))
    b64_text = base64.b64encode(text.encode("utf-8")).decode("ascii")
    print(f"MSG\t{uid}\t{chat_id}\t{str(is_bot).lower()}\t{b64_text}")
PY
}

extract_openclaw_text() {
  python3 - <<'PY'
import json
import sys

raw = sys.stdin.read().strip()
if not raw:
    print("")
    sys.exit(0)

try:
    data = json.loads(raw)
except Exception:
    print("")
    sys.exit(0)

text = ""

if isinstance(data, dict):
    result = data.get("result")
    if isinstance(result, dict):
        payloads = result.get("payloads")
        if isinstance(payloads, list) and payloads and isinstance(payloads[0], dict):
            candidate = payloads[0].get("text")
            if isinstance(candidate, str):
                text = candidate

if not text and isinstance(data, dict):
    payloads = data.get("payloads")
    if isinstance(payloads, list) and payloads and isinstance(payloads[0], dict):
        candidate = payloads[0].get("text")
        if isinstance(candidate, str):
            text = candidate

print(text)
PY
}

extract_last_json_object() {
  python3 - <<'PY'
import sys

s = sys.stdin.read()
if not s:
    print("")
    sys.exit(0)

i = len(s) - 1
while i >= 0 and s[i] != '}':
    i -= 1

if i < 0:
    print("")
    sys.exit(0)

depth = 0
in_str = False
escaped = False
start = -1

for j in range(i, -1, -1):
    ch = s[j]
    if in_str:
        if escaped:
            escaped = False
        elif ch == '\\':
            escaped = True
        elif ch == '"':
            in_str = False
        continue

    if ch == '"':
        in_str = True
    elif ch == '}':
        depth += 1
    elif ch == '{':
        depth -= 1
        if depth == 0:
            start = j
            break

if start >= 0:
    print(s[start:i + 1])
else:
    print("")
PY
}

log "tg_oc_bridge started. offset_file=${OFFSET_FILE} proxy=${HTTPS_PROXY:-<none>}"
send_tg_message "✅ bridge 启动成功" || true

while true; do
  offset="$(read_offset)"

  updates_resp="$(tg_api "getUpdates" \
    --get \
    --data-urlencode "timeout=${POLL_TIMEOUT}" \
    --data-urlencode "offset=${offset}")"
  updates_rc=$?
  updates_bytes=${#updates_resp}

  if [ ${updates_rc} -ne 0 ] || [ -z "${updates_resp}" ]; then
    log "WARN: poll offset=${offset} curl_rc=${updates_rc} bytes=${updates_bytes} parsed_msgs=0 entered=0"
    log "WARN: getUpdates curl cmd=$(build_curl_cmd_preview "getUpdates" --get --data-urlencode "timeout=${POLL_TIMEOUT}" --data-urlencode "offset=${offset}")"
    sleep "${RETRY_SLEEP}"
    continue
  fi

  lines=()
  mapfile -t lines < <(extract_updates <<<"${updates_resp}") || true
  if [ "${#lines[@]}" -eq 0 ]; then
    log "WARN: poll offset=${offset} curl_rc=${updates_rc} bytes=${updates_bytes} parsed_msgs=0 entered=0 parser_empty=1"
    sleep "${RETRY_SLEEP}"
    continue
  fi

  meta_line="${lines[0]}"
  max_update_id="$(awk -F'\t' '{print $2}' <<<"${meta_line}")"
  if [[ "${max_update_id}" =~ ^[0-9]+$ ]]; then
    write_offset "$((max_update_id + 1))"
  fi

  parsed_msgs=$(( ${#lines[@]} - 1 ))
  entered=0

  for ((i = 1; i < ${#lines[@]}; i++)); do
    line="${lines[$i]}"
    IFS=$'\t' read -r tag update_id chat_id is_bot text_b64 <<<"${line}"

    [ "${tag}" = "MSG" ] || continue
    [ "${chat_id}" = "${TG_CHAT_ID}" ] || continue
    [ "${is_bot}" = "false" ] || continue

    text="$(printf '%s' "${text_b64}" | base64 -d 2>/dev/null || true)"
    [ -n "${text}" ] || continue

    entered=1
    log "INFO: processing update_id=${update_id} chat_id=${chat_id}"

    send_tg_message "收到：${text}" || true

    oc_raw_full="$(openclaw agent --to default --message "${text}" --thinking minimal --timeout 120 --json)"
    oc_rc=$?
    if [ ${oc_rc} -eq 0 ]; then
      oc_raw="$(extract_last_json_object <<<"${oc_raw_full}")"
    else
      oc_raw=""
    fi

    if [ ${oc_rc} -ne 0 ]; then
      oc_reply="OpenClaw 调用失败/未返回文本"
      log "WARN: openclaw command failed rc=${oc_rc} preview=$(printf %.200s "${oc_raw_full}")"
    else
      oc_reply="$(extract_openclaw_text <<<"${oc_raw}")"
      if [ -z "${oc_reply}" ]; then
        oc_reply="OpenClaw 调用失败/未返回文本"
        log "WARN: openclaw json parse empty preview=$(printf %.200s "${oc_raw_full}")"
      fi
    fi

    send_tg_message "OpenClaw：${oc_reply}" || true
  done

  log "INFO: poll offset=${offset} curl_rc=${updates_rc} bytes=${updates_bytes} parsed_msgs=${parsed_msgs} entered=${entered}"
done
