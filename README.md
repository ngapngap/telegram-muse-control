# telegram-muse-control

Control Muse entirely through a Telegram bot — no feature restrictions, in
private chat and in groups. Muse reads your messages from the bot and replies
on Telegram, in near-realtime.

> This is a personal setup built on 2026-11-10. Hook design since
> 2026-11-19 (see below); the listener + cron design it replaced is kept
> as rollback. The helper is designed to run
> inside Muse's own environment: it reads the bot token from Muse's registered
> credential through a surrogate, so **no token ever appears in this repo**,
> in arguments, or in logs. Do not paste a bot token into any file here.

## How it works

- **Bot**: `@YOUR_BOT_USERNAME` (Telegram Bot API, long-poll `getUpdates`).
  No webhook is set — webhook and long-poll are mutually exclusive, and this
  setup polls.
- **Event hook `telegram-inbox`** (since 2026-11-19, current design): a Muse
  hook runs `hooks/telegram-inbox.sh` every 30 seconds. The script long-polls
  `updates --timeout 25` under `state/poll.lock`, filters with the group rule
  below, queues qualifying messages to `~/hooks/state/telegram/inbox.jsonl`,
  then advances the offset — and wakes a worker agent ONLY when a message was
  queued. When idle it costs ~0 tokens. The worker (prompt in
  `hooks/telegram-inbox-worker.md`) drains the inbox atomically, replies on
  Telegram, and dedupes via `sent-ids.txt`.
- **Why a hook, not a listener**: the previous always-on listener + 1-minute
  cron burned ~500M tokens/day just staying alive (~3.5B tokens in 7 days,
  plus the listener's own unrecorded burn). The hook costs ~0 when idle and
  ~200k tokens per answered message (measured 2026-11-19).
- **Runs inside Muse**: the hook is a Muse event hook, not a standalone
  daemon — it only works in an environment with Muse's hook runtime.
- **Single consumer + offset**: Telegram allows only one active `getUpdates`
  consumer — concurrent callers collide with `409 Conflict`. All polling goes
  through `state/poll.lock`. After handling every returned update, store
  `max(update_id) + 1` with `set-offset`, even for ignored updates.

## Setup — turn privacy OFF (required)

The tag rule below only works if the bot actually receives every group
message. By default Telegram bots run in privacy mode: they only see
messages that mention them or are commands. Turn privacy OFF once, in
BotFather:

1. Open @BotFather on Telegram and send `/setprivacy`.
2. Pick your bot from the list.
3. Tap **Disable**.
4. Remove the bot from each group, then add it back. This step is
   required: a privacy change only takes effect for a bot after it is
   removed and re-added to the group.
5. Verify: run `getme`. `can_read_all_group_messages` must be `true`.
   If it is still `false`, repeat step 4.

With privacy OFF, the bot receives every group message — and the
mention-only rule below decides which ones get a reply. Do NOT rely on
Telegram's privacy mode to do the filtering: mentions were not arriving
reliably even with privacy ON, which is why the rule lives on our side.

## The group rule — reply only when tagged (mention-only)

The bot receives every group message (privacy OFF), but replies only when
the message is addressed to it. The check runs in two places — the hook
script's filter and the worker's re-check before sending — so the rule holds
even if one of them is bypassed. Reply to a group message only if ANY of these is
true:

- (a) its text contains `@YOUR_BOT_USERNAME` (an @mention), or
- (b) it is a reply to one of the bot's own messages
  (`reply_to_message.from.id == YOUR_BOT_ID`), or
- (c) it is a command (its text starts with `/`).

Otherwise ignore the message silently — do NOT reply — but still advance
the update offset past it, so it is not delivered again. In the private
DM the rule does not apply: the bot replies to every message there.

In a forum supergroup, send the reply with `--thread-id` set to the
incoming message's `message_thread_id`, so the reply lands in the same
topic. (The General topic is thread `1`, which Telegram rejects on send —
omit the flag there.)

## Adding a new group

1. Add the bot to the group.
2. Find the group's chat id (it starts with `-100` for supergroups; a
   plain negative number is missing that prefix).
3. Add the chat id to `ALLOWED_CHATS` in `hooks/telegram-inbox.sh`, to the
   worker prompt in `hooks/telegram-inbox-worker.md`, and to
   `docs/POLLING.md`. Until then the bot sees the messages but
   ignores them. The same mention-only rule applies automatically.

## If Muse restarts

The hook is re-run by the runtime every 30 seconds, so there is no
long-running listener to die on a restart. If replies stop, check that
the hook is still enabled and that its last run was silent with no
error. Messages already queued in `inbox.jsonl` are picked up by the
next wake — a stale `processing-*.jsonl` file older than 600 seconds is
requeued automatically.

**Rollback to the previous design.** Before 2026-11-19 the bridge ran
on a realtime listener agent plus two crons. That setup is kept as the
fallback: disable the hook, then re-enable the `telegram-poll-replies`
(1 minute) and `telegram-listener-watchdog` (5 minutes) crons. The
fallback cron reads the listener heartbeat (`state/heartbeat.txt`) and
polls Telegram itself when it is older than 120 seconds; the watchdog
spawns a new listener when it is older than 600 seconds. A spawned
listener first checks the heartbeat itself: if it is less than 60
seconds old, another listener is already alive and it exits at once, so
two listeners can never poll at the same time (Telegram allows only one
active `getUpdates` consumer).

Verified by test on 2026-11-10: the live listener was stopped and the
heartbeat backdated; the watchdog respawned it, and the new listener
kept polling on its own afterwards. Verified 2026-11-19: a queued test
message woke the worker, the reply was delivered, and the inbox was
drained clean. If replies ever stop entirely, check the hook logs first —
and if the hook is down, the rollback crons above are already answering
within a minute.

## Files

| File | What it is |
| --- | --- |
| `bin/telegram.py` | Bot API helper: `getme`, `updates [--timeout N]`, `send`, `send-photo`, `chat-member`, `chat-admins`, `webhook-info`, `get-offset`, `set-offset` |
| `hooks/telegram-inbox.sh` | Hook script: polls `getUpdates`, filters with the group rule, queues to the inbox, wakes the worker only on real messages |
| `hooks/telegram-inbox-worker.md` | Worker prompt: how the woken agent drains the inbox and replies |
| `docs/CONNECTOR.md` | Connector doc: credential setup, commands, error recovery |
| `docs/POLLING.md` | Polling runbook: hook design, worker, group rule, rollback |
| `connector.yaml` | Muse custom-connector descriptor (`custom.telegram`) |

## Setup notes (from the live install)

- Groups: `YOUR_GROUP_NAME` (`YOUR_GROUP_ID`, forum; messages live in
  the `Muse` topic, thread `YOUR_TOPIC_THREAD_ID`). More groups can be
  added — see 'Adding a new group' above. A bot that is a group admin receives all
  messages regardless of privacy mode — but only the group creator can
  promote it, so this setup uses privacy OFF instead.
- Privacy changes in BotFather only take effect for a bot after it is removed
  from the group and re-added.
- Verified 2026-11-10: a tagged group message got its reply in the topic;
  an untagged one got no reply, by design. DM replies land in ~6 seconds.
- Verified 2026-11-19: the hook design — a queued test message woke the
  worker, the reply was delivered to the DM, and one wake cost ~202k
  tokens. Idle polling costs ~0 tokens.
- Video generation is not available for this account in its country/region —
  the bot offers an image instead when asked for a video.
