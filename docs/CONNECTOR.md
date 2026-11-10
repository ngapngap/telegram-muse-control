# Telegram

- `custom.telegram` connects Muse to Telegram through the Telegram Bot API. It authenticates with the registered `api_key` credential and calls only `api.telegram.org`.

- The bot token is placed in the URL path as `https://api.telegram.org/bot<token>/METHOD`. Helpers build that URL with the raw surrogate from `dynamic_credentials.py` and never quote it, because quoting the surrogate breaks the credential exchange and Telegram answers 404.

- Helpers live in `~/workspace/custom-connectors/custom.telegram/bin/`. `telegram.py` runs `getme`, `updates`, `send`, `get-offset` and `set-offset`. The polling runbook lives in `~/workspace/custom-connectors/custom.telegram/POLLING.md`.

## Connect

- The connection was registered with `credentials.request_api_access` and these details. Reuse them to reconnect.

```json
{
  "provider": "telegram",
  "auth_scheme": "api_key",
  "placement": "url_path_segment:/bot{}",
  "api_hosts": ["api.telegram.org"]
}
```

- Before the first change in a conversation, prove access with a harmless read:

```text
python3 ~/workspace/custom-connectors/custom.telegram/bin/telegram.py getme
```

- The read above was verified on 2026-11-10. It returned the bot `@YOUR_BOT_USERNAME` with id YOUR_BOT_ID.

## Credentials

- The registered connection holds the credential. Helpers import `/opt/muse/skills/custom-connector-setup/bin/dynamic_credentials.py`, which returns an `hsurr:` surrogate and places it where the provider reads the key. Muse swaps in the real credential only on an approved request to a registered host.

- Never put a key, token, password or cookie in this doc, a helper, a command argument, an environment variable or a log. Never ask the user to paste one in chat.

- Keep redirects disabled on authenticated requests.

- On a 401 or 403, check the request first. Confirm that the helper attached the credential, that the host is registered and that the placement and scopes match.

- Only when a request that carried the credential is still rejected, call `credentials.request_api_access` with the details above and `"reconnect": true`.

## Check the bot identity

- `getme` is a read that tests the token and returns the bot user object.

```text
python3 ~/workspace/custom-connectors/custom.telegram/bin/telegram.py getme
```

- Read the `result.username`, `result.id` and `result.can_read_all_group_messages` fields. A `false` value for `can_read_all_group_messages` means the bot only sees group messages that mention it or are commands, unless privacy mode is disabled in BotFather.

## Read new messages

- `updates` is a read that returns pending updates as JSON. With no `--offset` it reads the stored offset from `state/offset.txt`.

```text
python3 ~/workspace/custom-connectors/custom.telegram/bin/telegram.py updates
```

- Each update carries `update_id`, and each `message` carries `message_id`, `chat.id`, `chat.type`, `chat.title`, `from.id`, `from.username`, `text` and `date`. `my_chat_member` updates have no `message` and carry no text.

- After handling every returned update, store max `update_id` plus 1 with `set-offset`, even for ignored updates, so they are not returned again.

```text
python3 ~/workspace/custom-connectors/custom.telegram/bin/telegram.py set-offset 15786848
```

## Send a message

- `send` is a change that posts one text message from the bot. Text is truncated to 4096 chars by the helper.

```text
python3 ~/workspace/custom-connectors/custom.telegram/bin/telegram.py send --chat-id YOUR_USER_ID --text "hello"
```

- `chat_id` is the Telegram chat id. Private chats use a positive id and groups use a negative id. In a forum supergroup, pass `--thread-id` with the incoming message's `message_thread_id` when present, so the reply lands in the right topic.

- The call was verified on 2026-11-10. It returned `ok` true and a `message_id` in the user's private chat.

## Recover from errors

- A 404 with description `Not Found` means Telegram did not recognise the token in the URL path. Check that the helper attached the raw surrogate without quoting it, and that the stored credential is the right bot token.

- A 401 or 403 means the credential was rejected. Check that the request carried the credential and that the host is registered, then reconnect only when a request that carried it is still rejected.

- After a failed or timed-out change, check the current state with a read before trying again, because the first request may have completed.

## Limits

- The Bot API cannot start a conversation. The bot can only message a user who messaged it first or a group it was added to.

- The bot only reads group messages that mention it or are commands, unless privacy mode is disabled in BotFather.

- No webhook is set on this bot. Do not call `setWebhook`, because it stops `getUpdates` from returning updates.

- Sending files, photos and other media is untested. Text messages are the only verified operation.

## Related skills

- Use `muse.skill_search` to find other skills and `muse.connector_search` to find other connectors.
