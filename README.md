# telegram-muse-control

Control Muse entirely through a Telegram bot — no feature restrictions, in
private chat and in groups. Muse reads your messages from the bot and replies
on Telegram, in near-realtime.

> This is a personal setup built on 2026-11-10. The helper is designed to run
> inside Muse's own environment: it reads the bot token from Muse's registered
> credential through a surrogate, so **no token ever appears in this repo**,
> in arguments, or in logs. Do not paste a bot token into any file here.

## How it works

- **Bot**: `@YOUR_BOT_USERNAME` (Telegram Bot API, long-poll `getUpdates`).
  No webhook is set — webhook and long-poll are mutually exclusive, and this
  setup polls.
- **Realtime listener**: a long-running agent loops
  `updates --timeout 30` and replies in ~5–15 seconds. It writes a heartbeat
  to `state/heartbeat.txt` every loop.
- **Fallback cron**: runs every 1 minute, but exits silently when the
  listener heartbeat is less than 120 seconds old, so the two never poll at
  the same time. Telegram allows only one active `getUpdates` consumer —
  concurrent callers collide with `409 Conflict`.
- **Offset**: after handling every returned update, store `max(update_id) + 1`
  with `set-offset`, even for ignored updates.

## The group rule (mention-only, enforced by the listener)

Telegram's privacy mode proved unreliable for mentions, so the rule lives on
our side instead. The bot receives **every** group message (privacy OFF in
BotFather, bot removed and re-added once so the change takes effect), but
replies only when the message:

- contains `@YOUR_BOT_USERNAME`, or
- replies to one of the bot's own messages, or
- is a command (text starts with `/`).

Untagged group messages are ignored silently (the offset still advances).
Private chat is unaffected: the bot replies to every message there.

In a forum supergroup, replies must pass `--thread-id` with the incoming
message's `message_thread_id`, so the reply lands in the right topic.
(The General topic is thread `1`, which Telegram rejects on send — omit the
flag there.)

## Files

| File | What it is |
| --- | --- |
| `bin/telegram.py` | Bot API helper: `getme`, `updates [--timeout N]`, `send`, `send-photo`, `chat-member`, `chat-admins`, `webhook-info`, `get-offset`, `set-offset` |
| `docs/CONNECTOR.md` | Connector doc: credential setup, commands, error recovery |
| `docs/POLLING.md` | Polling runbook: listener, fallback cron, the group rule |
| `connector.yaml` | Muse custom-connector descriptor (`custom.telegram`) |

## Setup notes (from the live install)

- Group: `YOUR_GROUP_NAME`, supergroup `YOUR_GROUP_ID` (forum; messages live in
  the `Muse` topic, thread `YOUR_TOPIC_THREAD_ID`). A bot that is a group admin receives all
  messages regardless of privacy mode — but only the group creator can
  promote it, so this setup uses privacy OFF instead.
- Privacy changes in BotFather only take effect for a bot after it is removed
  from the group and re-added.
- Verified 2026-11-10: a tagged group message got its reply in the topic;
  an untagged one got no reply, by design. DM replies land in ~6 seconds.
- Video generation is not available for this account in its country/region —
  the bot offers an image instead when asked for a video.
