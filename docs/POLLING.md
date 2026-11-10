# Telegram polling runbook

Bot: @YOUR_BOT_USERNAME. Direct polling only, no Cloudflare, no Worker.
User's Telegram id: YOUR_USER_ID (YOUR_NAME). Private DM chat: YOUR_USER_ID.
Groups: "YOUR_GROUP_NAME", supergroup id YOUR_GROUP_ID (forum supergroup),
and a second group, supergroup id YOUR_SECOND_GROUP_ID. Same mention-only
rule in both groups.

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

## If Muse restarts

The listener dies when Muse or its VM restarts. Two safeguards cover
that:

1. **Fallback cron (1 minute).** It reads the heartbeat every minute;
   if the heartbeat is older than 120 seconds, it polls Telegram itself
   and answers. Replies keep working, just slower (within about a
   minute).
2. **Watchdog cron (5 minutes, job `telegram-listener-watchdog`).** It
   checks the heartbeat every 5 minutes; if it is older than 600
   seconds, it spawns a new realtime listener with the same brief. A
   spawned listener first checks the heartbeat itself: if it is less
   than 60 seconds old, another listener is already alive and it exits
   at once, so two listeners never poll at the same time.

Verified by test on 2026-11-10: the live listener was stopped and the
heartbeat backdated; the watchdog respawned it, and the new listener
kept polling on its own afterwards.

## Privacy OFF setup (step by step — do this first)

The tag rule below only works if the bot receives every group message.
By default Telegram bots run in privacy mode: they only see messages
that mention them or are commands. Turn privacy OFF once, in BotFather:

1. Open @BotFather on Telegram and send `/setprivacy`.
2. Pick your bot from the list.
3. Tap **Disable**.
4. Remove the bot from each group, then add it back. This step is
   required: a privacy change only takes effect for a bot after it is
   removed and re-added to the group.
5. Verify: run `getme`. `can_read_all_group_messages` must be `true`.
   If it is still `false`, repeat step 4.

Do NOT rely on Telegram's privacy mode to do the filtering: mentions
were not arriving reliably even with privacy ON, which is why the rule
below lives on our side instead.

## Group reply rule — mention-only, enforced by the listener (since 2026-11-10 ~12:44)

The bot receives every group message (privacy OFF), but replies only
when the message is addressed to it. The check runs in two places — the
realtime listener and the 1-minute fallback cron — so the rule holds even
if the listener dies. Reply to a group message only if ANY of these is
true: (a) its text contains '@YOUR_BOT_USERNAME', (b) it is a reply to
one of the bot's own messages (reply_to_message.from.id ==
YOUR_BOT_ID), (c) it is a command (text starts with '/'). Otherwise
ignore it silently — do NOT reply — but still advance the offset past
it, so it is not delivered again. The private DM is unaffected: reply
to every message there.

## Polling job (every 1 minute — FALLBACK ONLY, since 2026-11-10 ~12:10)

Step 0 of every run: read `state/heartbeat.txt`; if its Unix time is less
than 120 seconds old, the listener is alive — finish silently and do
nothing. Only when the file is missing or older than 120 seconds, run the
steps below (the listener has died and this run is the fallback).

1. Run `updates` and read the returned updates.
2. For each update with a `message.text`, only act on messages from
   `from.id` YOUR_USER_ID, in private chat YOUR_USER_ID or groups
   YOUR_GROUP_ID, YOUR_SECOND_GROUP_ID.
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
