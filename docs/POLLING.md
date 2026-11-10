# Telegram polling runbook (draft — needs the custom.telegram connection first)

Bot: @YOUR_BOT_USERNAME. Direct polling only, no Cloudflare, no Worker.
User's Telegram id: YOUR_USER_ID (YOUR_NAME). Private DM chat: YOUR_USER_ID.
Group: "YOUR_GROUP_NAME", supergroup id YOUR_GROUP_ID (forum supergroup).

## Helper

`python3 ~/workspace/custom-connectors/custom.telegram/bin/telegram.py <command>`

- `getme` — verify the token, prints bot id and username.
- `updates [--timeout N]` — prints pending updates as JSON. Reads the stored offset from
  `state/offset.txt` when no `--offset` is given. `--timeout` (0-50) is the
  Telegram long-poll timeout: the call blocks up to N seconds and returns
  instantly when a message arrives (verified: --timeout 5 waited 5.7s).
  Offset is already set to 15786848, skipping the /start, "ê mày" and group-join updates that were
  answered manually on 2026-11-10 ~11:40.
- `send --chat-id ID --text TEXT [--thread-id N]` — send one text message.
  Text is truncated to 4096 chars. In the forum group, pass `--thread-id`
  with the incoming message's `message_thread_id` when present, so the
  reply lands in the right topic.
- `send-photo --chat-id ID --photo /path/to/image.png [--caption TEXT] [--thread-id N]` — upload a local image file to the chat via sendPhoto (multipart). Use it for image requests; generate the image first, then send it.
- `webhook-info` — show whether a webhook is set and how many updates are pending (should be url "" and pending 0; a set webhook would break getUpdates).
- `chat-member --chat-id ID --user-id ID` — show one member's status/rights in a chat.
- `chat-admins --chat-id ID` — list a chat's administrators (creator first).
- `set-offset N` — store offset N after a poll run.

## Realtime listener (since 2026-11-10 ~12:10)

A long-running listener agent loops `updates --timeout 30` and replies
immediately, so replies land in ~5-15 seconds instead of waiting for the
cron. Each iteration it first writes the current Unix time to
`state/heartbeat.txt`. If it is busy with a long task the heartbeat ages
and the cron below takes over.

## Group reply rule — mention-only, enforced by the listener (since 2026-11-10 ~12:44)

The user asked for the rule to live on our side, not in Telegram's privacy
setting: the bot receives every group message (privacy OFF), but replies
only when the message tags it. Reply to a group message only if ANY of
these is true: (a) its text contains '@YOUR_BOT_USERNAME', (b) it is a
reply to one of the bot's own messages (reply_to_message.from.id ==
YOUR_BOT_ID), (c) it is a command (text starts with '/'). Otherwise ignore
it silently but still advance the offset past it. The private DM is
unaffected: reply to every message there. The 1-minute fallback cron
applies the same rule. This replaces the earlier plan of relying on
Telegram's privacy mode, because mentions were not arriving reliably even
with privacy ON.

## Polling job (every 1 minute — FALLBACK ONLY, since 2026-11-10 ~12:10)

Step 0 of every run: read `state/heartbeat.txt`; if its Unix time is less
than 120 seconds old, the listener is alive — finish silently and do
nothing. Only when the file is missing or older than 120 seconds, run the
steps below (the listener has died and this run is the fallback).

1. Run `updates` and read the returned updates.
2. For each update with a `message.text`, only act on messages from
   `from.id` YOUR_USER_ID, in private chat YOUR_USER_ID or group YOUR_GROUP_ID.
   Ignore messages from anyone else, and ignore non-text updates and
   `my_chat_member` updates.
3. Answer as Muse, with the user's full context from memory. Reply with
   `send` to the same `chat.id` (and `message_thread_id` when present).
   Keep replies short enough for Telegram; split only if a reply must
   exceed 4096 chars.
4. After handling every returned update, run `set-offset` with
   max(update_id) + 1, even for ignored updates, so they are not returned
   again. Do this only after the replies for that batch were sent.
5. If `getme` or `updates` returns 401/403, stop and report it — do not
   retry the same call unchanged. The token may need reconnecting.

## Notes

- No webhook is set on this bot, so `getUpdates` works. Do not call
  `setWebhook` — it would stop `getUpdates` from returning updates, and
  webhook and long-polling are mutually exclusive in Telegram: a bot can
  use one or the other, not both. The Cloudflare Worker webhook design was
  abandoned for this reason (and its browser task stalled ~11 min on the
  Cloudflare login challenge on 2026-11-10 ~12:06 before being stopped);
  the Worker shell `muse-telegram-bridge` still exists with default code.
- In groups the bot only sees messages that mention it or are commands,
  unless privacy mode is disabled in BotFather (`/setprivacy` -> Disable).
- This bot does no mail work. The mail-code Worker is separate
  (`resend-code-filter`) and must not be touched by this bridge.
