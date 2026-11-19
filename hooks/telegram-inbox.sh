#!/usr/bin/env bash
# Telegram inbox poller (hook script for the @YOUR_BOT_USERNAME bridge).
#
# Replaces the 1-minute Muse-agent fallback cron and the listener subagent's
# polling loop. This script is NOT an agent: it long-polls getUpdates, keeps
# only the messages Muse should answer, queues them, and wakes a worker
# agent ONLY when there is real work. When idle it costs zero tokens.
#
# Single-consumer rule: at most one getUpdates caller at a time. All polling
# goes through state/poll.lock (shared with the old listener). The stored
# offset in state/offset.txt is advanced only after a successful poll whose
# qualifying messages were queued.
#
# Dry runs (HATCH_HOOK_DRY_RUN=1) are read-only: they poll and filter, but
# never write heartbeat/offset/inbox/counters.
set -euo pipefail
source "$HATCH_HOOK_RUNTIME"

TG_STATE="$HOME/workspace/custom-connectors/custom.telegram/state"
TG_HELPER="$HOME/workspace/custom-connectors/custom.telegram/bin/telegram.py"
HOOK_DIR="$HOME/hooks/state/telegram"
INBOX="$HOOK_DIR/inbox.jsonl"
INBOX_LOCK="$HOOK_DIR/inbox.lock"
FAILURES="$HOOK_DIR/failures.txt"
LAST_AUTH_WAKE="$HOOK_DIR/last-auth-wake.txt"
LAST_WAKE="$HOOK_DIR/last-wake.txt"
DRY="${HATCH_HOOK_DRY_RUN:-0}"
mkdir -p "$HOOK_DIR"

now_s() { date +%s; }

# --- Crash recovery: requeue stale processing files (live mode only). ---
if [ "$DRY" != "1" ]; then
  for proc in "$HOOK_DIR"/processing-*.jsonl; do
    [ -f "$proc" ] || continue
    age=$(( $(now_s) - $(stat -c %Y "$proc") ))
    if [ "$age" -gt 600 ]; then
      {
        flock -x 8
        cat "$proc" >> "$INBOX"
        rm -f "$proc"
      } 8>"$INBOX_LOCK"
      log "telegram requeued stale processing file" "{\"file\": \"$(basename "$proc")\", \"age_s\": $age}"
    fi
  done
fi

# --- Backlog: unprocessed messages left in the inbox? ---
backlog_count=0
[ -f "$INBOX" ] && backlog_count=$(wc -l < "$INBOX" | tr -d ' ')
last_wake=0
[ -f "$LAST_WAKE" ] && last_wake=$(cat "$LAST_WAKE" 2>/dev/null || echo 0)
backlog_wake=0
if [ "$backlog_count" -gt 0 ] && [ $(( $(now_s) - last_wake )) -gt 180 ]; then
  backlog_wake=1
fi

# --- Poll Telegram under the shared lock. ---
# If the lock is held, another poller (the old listener, during cutover) is
# mid-poll: do not call getUpdates (409 risk), just honour a backlog wake.
exec 9>"$TG_STATE/poll.lock" || {
  log "telegram poll lock open failed" '{}'
  silent "telegram poll lock unavailable"
}
if ! flock -n 9; then
  if [ "$backlog_wake" = "1" ]; then
    [ "$DRY" != "1" ] && now_s > "$LAST_WAKE"
    wake "telegram-backlog" "{\"queued\": $backlog_count}"
  fi
  silent "telegram poll locked by another poller"
fi

[ "$DRY" != "1" ] && now_s > "$TG_STATE/heartbeat.txt"

UPDATES_JSON="$HOOK_DIR/last-updates.json"
POLL_ERR="$HOOK_DIR/last-error.txt"
if ! python3 "$TG_HELPER" updates --timeout 25 > "$UPDATES_JSON" 2>"$POLL_ERR"; then
  err=$(head -c 300 "$POLL_ERR" | tr '\n' ' ')
  log "telegram updates call failed" "{\"error\": $(printf '%s' "$err" | jq -Rs .)}"
  if [ "$DRY" != "1" ]; then
    n=1
    [ -f "$FAILURES" ] && n=$(( $(cat "$FAILURES" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$FAILURES"
    last_auth=0
    [ -f "$LAST_AUTH_WAKE" ] && last_auth=$(cat "$LAST_AUTH_WAKE" 2>/dev/null || echo 0)
    if [ "$n" -ge 3 ] && [ $(( $(now_s) - last_auth )) -gt 3600 ]; then
      now_s > "$LAST_AUTH_WAKE"
      echo 0 > "$FAILURES"
      wake "telegram-poll-error" "{\"consecutive_failures\": $n, \"error\": $(printf '%s' "$err" | jq -Rs .)}"
    fi
  fi
  silent "telegram updates call failed"
fi
[ "$DRY" != "1" ] && echo 0 > "$FAILURES"

# --- Filter updates with python: queue only messages Muse should answer. ---
# Prints one JSON summary line: {ok, total, qualifying, ignored, max_id, preview}
SUMMARY="$(python3 - "$UPDATES_JSON" "$INBOX" "$INBOX_LOCK" "$DRY" <<'PYEOF'
import json, sys
updates_path, inbox_path, inbox_lock, dry = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
# Fill in your own numeric IDs: bot id from getme, your Telegram user id,
# and the chat ids of the DM and groups the bot should answer in.
BOT_ID = YOUR_BOT_ID
USER_ID = YOUR_USER_ID
ALLOWED_CHATS = {YOUR_USER_ID, YOUR_GROUP_ID, YOUR_SECOND_GROUP_ID}
try:
    data = json.load(open(updates_path))
except Exception as exc:
    print(json.dumps({"ok": False, "error": f"bad updates json: {exc}"}))
    sys.exit(0)
if not data.get("ok"):
    print(json.dumps({"ok": False, "error": str(data.get("description", "telegram api not ok"))[:200]}))
    sys.exit(0)
results = data.get("result", [])
qualifying = []
max_id = None
for upd in results:
    uid = upd.get("update_id")
    if isinstance(uid, int):
        max_id = uid if max_id is None else max(max_id, uid)
    msg = upd.get("message")
    if not isinstance(msg, dict):
        continue
    text = msg.get("text")
    if not isinstance(text, str) or not text:
        continue
    frm = msg.get("from") or {}
    if frm.get("id") != USER_ID:
        continue
    chat = msg.get("chat") or {}
    chat_id = chat.get("id")
    if chat_id not in ALLOWED_CHATS:
        continue
    if chat_id != USER_ID:
        reply_to = msg.get("reply_to_message") or {}
        reply_from = (reply_to.get("from") or {}).get("id")
        if ("@YOUR_BOT_USERNAME" not in text
                and reply_from != BOT_ID
                and not text.startswith("/")):
            continue
    qualifying.append({
        "update_id": uid,
        "chat_id": chat_id,
        "thread_id": msg.get("message_thread_id"),
        "from_id": USER_ID,
        "text": text,
        "date": msg.get("date"),
    })
if dry != "1" and qualifying:
    import fcntl
    with open(inbox_lock, "w") as lock_f:
        fcntl.flock(lock_f, fcntl.LOCK_EX)
        with open(inbox_path, "a", encoding="utf-8") as out:
            for item in qualifying:
                out.write(json.dumps(item, ensure_ascii=False) + "\n")
preview = qualifying[0]["text"][:200] if qualifying else ""
print(json.dumps({
    "ok": True,
    "total": len(results),
    "qualifying": len(qualifying),
    "ignored": len(results) - len(qualifying),
    "max_id": max_id,
    "preview": preview,
}, ensure_ascii=False))
PYEOF
)"
filter_ok="$(printf '%s' "$SUMMARY" | jq -r '.ok' 2>/dev/null || echo false)"
if [ "$filter_ok" != "true" ]; then
  log "telegram updates filter failed" "{\"summary\": $(printf '%s' "$SUMMARY" | jq -Rs .)}"
  silent "telegram updates filter failed, offset not advanced"
fi

# --- Advance the offset (live mode only, only after queueing). ---
max_id="$(printf '%s' "$SUMMARY" | jq -r '.max_id' 2>/dev/null || echo null)"
if [ "$DRY" != "1" ] && [ "$max_id" != "null" ] && [ -n "$max_id" ]; then
  python3 "$TG_HELPER" set-offset $((max_id + 1)) >/dev/null 2>&1 || true
fi

new_count="$(printf '%s' "$SUMMARY" | jq -r '.qualifying' 2>/dev/null || echo 0)"
total_count="$(printf '%s' "$SUMMARY" | jq -r '.total' 2>/dev/null || echo 0)"
log "telegram poll done" "{\"total\": $total_count, \"new_queued\": $new_count, \"inbox\": $backlog_count}"

if [ "$new_count" -gt 0 ]; then
  [ "$DRY" != "1" ] && now_s > "$LAST_WAKE"
  if [ "$DRY" = "1" ]; then
    silent "dry run: would wake for $new_count new telegram message(s)"
  fi
  wake "telegram-message" "{\"new_messages\": $new_count, \"preview\": $(printf '%s' "$SUMMARY" | jq -c '.preview')}"
fi
if [ "$backlog_wake" = "1" ]; then
  [ "$DRY" != "1" ] && now_s > "$LAST_WAKE"
  if [ "$DRY" = "1" ]; then
    silent "dry run: would wake for $backlog_count queued telegram message(s)"
  fi
  wake "telegram-backlog" "{\"queued\": $backlog_count}"
fi
silent "telegram poll: no new messages"
