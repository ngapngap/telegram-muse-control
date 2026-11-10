#!/usr/bin/env python3
"""Telegram Bot API helper for the custom.telegram connector.

Uses the registered custom.telegram credential through a surrogate, so no
bot token ever appears in this file, in arguments, or in logs. The token
lives in the registered connection and is placed in the URL path as
https://api.telegram.org/bot<token>/METHOD, which is how the Bot API reads it.

Commands:
  getme                              verify the token, print bot id/username
  updates [--offset N]               print pending updates as JSON; with no
                                     --offset, reads state/offset.txt
  send --chat-id ID --text TEXT [--thread-id N]
                                     send one text message (max 4096 chars)
  get-offset                         print the stored offset, or nothing
  set-offset N                       store offset N in state/offset.txt

Offset rule for the polling job: after handling every update returned by
`updates`, store max(update_id) + 1 with `set-offset`, even for updates
that were ignored, so they are not returned again.
"""

import argparse
import json
import mimetypes
import os
import sys
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

sys.path.insert(0, "/opt/muse/skills/custom-connector-setup/bin")
from dynamic_credentials import (
    DynamicCredentialError,
    dynamic_credential_entry,
    read_json_response,
)

ALLOWED_HOSTS = ["api.telegram.org"]
CREDENTIAL = "custom.telegram"
BASE_TEMPLATE = "https://api.telegram.org/bot{}/{}"
STATE_FILE = Path(__file__).resolve().parent.parent / "state" / "offset.txt"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        raise RuntimeError("redirect refused, verify the endpoint")


def method_url(method):
    entry = dynamic_credential_entry(CREDENTIAL)
    placement = entry.get("placement")
    if not (isinstance(placement, dict) and "url_path_segment" in placement):
        raise DynamicCredentialError(f"credential is not url_path_segment: {placement!r}")
    surrogate = str(entry["surrogate"]).strip()
    if not surrogate.startswith("hsurr:"):
        raise DynamicCredentialError("authd returned a non-surrogate value")
    return "https://api.telegram.org/bot" + surrogate + "/" + method


def call(method, payload=None, query=None, http_timeout=30):
    url = method_url(method)
    if query:
        url += "?" + urllib.parse.urlencode(query)
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    headers = {"Content-Type": "application/json"} if data else {}
    request = urllib.request.Request(url, data=data, headers=headers, method="POST" if data else "GET")
    with urllib.request.build_opener(NoRedirect()).open(request, timeout=http_timeout) as response:
        return read_json_response(response)


def send_photo(chat_id, photo_path, caption=None, thread_id=None):
    """POST a photo file to sendPhoto as multipart/form-data."""
    if not os.path.isfile(photo_path):
        raise RuntimeError(f"photo file not found: {photo_path}")
    boundary = uuid.uuid4().hex
    body = b""

    def field(name, value):
        nonlocal body
        body += f"--{boundary}\r\n".encode("utf-8")
        body += f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode("utf-8")
        body += str(value).encode("utf-8") + b"\r\n"

    field("chat_id", chat_id)
    if caption:
        field("caption", caption[:1024])
    if thread_id is not None:
        field("message_thread_id", thread_id)
    filename = os.path.basename(photo_path)
    mime = mimetypes.guess_type(photo_path)[0] or "image/jpeg"
    with open(photo_path, "rb") as handle:
        data = handle.read()
    body += f"--{boundary}\r\n".encode("utf-8")
    body += f'Content-Disposition: form-data; name="photo"; filename="{filename}"\r\n'.encode("utf-8")
    body += f"Content-Type: {mime}\r\n\r\n".encode("utf-8")
    body += data + b"\r\n"
    body += f"--{boundary}--\r\n".encode("utf-8")
    request = urllib.request.Request(
        method_url("sendPhoto"),
        data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        method="POST",
    )
    with urllib.request.build_opener(NoRedirect()).open(request, timeout=60) as response:
        return read_json_response(response)


def read_offset():
    try:
        return int(STATE_FILE.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return None


def main():
    parser = argparse.ArgumentParser(description="Telegram Bot API helper")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("getme")
    sub.add_parser("webhook-info")
    chat_member = sub.add_parser("chat-member")
    chat_member.add_argument("--chat-id", required=True)
    chat_member.add_argument("--user-id", required=True)
    chat_admins = sub.add_parser("chat-admins")
    chat_admins.add_argument("--chat-id", required=True)
    updates = sub.add_parser("updates")
    updates.add_argument("--offset", type=int, default=None)
    updates.add_argument("--timeout", type=int, default=0, help="Long-poll timeout in seconds (0-50, Telegram max 50)")
    send = sub.add_parser("send")
    send.add_argument("--chat-id", required=True)
    send.add_argument("--text", required=True)
    send.add_argument("--thread-id", type=int, default=None)
    send_photo_parser = sub.add_parser("send-photo")
    send_photo_parser.add_argument("--chat-id", required=True)
    send_photo_parser.add_argument("--photo", required=True, help="Local image file path to upload")
    send_photo_parser.add_argument("--caption", default=None)
    send_photo_parser.add_argument("--thread-id", type=int, default=None)
    sub.add_parser("get-offset")
    set_offset = sub.add_parser("set-offset")
    set_offset.add_argument("offset", type=int)
    args = parser.parse_args()

    try:
        if args.command == "getme":
            print(json.dumps(call("getMe"), ensure_ascii=False))
        elif args.command == "webhook-info":
            print(json.dumps(call("getWebhookInfo"), ensure_ascii=False))
        elif args.command == "chat-member":
            print(json.dumps(call("getChatMember", payload={"chat_id": int(args.chat_id), "user_id": int(args.user_id)}), ensure_ascii=False))
        elif args.command == "chat-admins":
            print(json.dumps(call("getChatAdministrators", payload={"chat_id": int(args.chat_id)}), ensure_ascii=False))
        elif args.command == "updates":
            offset = args.offset if args.offset is not None else read_offset()
            timeout = max(0, min(50, args.timeout))
            query = {"timeout": timeout}
            if offset is not None:
                query["offset"] = offset
            print(json.dumps(call("getUpdates", query=query, http_timeout=timeout + 15), ensure_ascii=False))
        elif args.command == "send":
            text = args.text[:4096]
            payload = {"chat_id": int(args.chat_id), "text": text}
            if args.thread_id is not None:
                payload["message_thread_id"] = args.thread_id
            print(json.dumps(call("sendMessage", payload=payload), ensure_ascii=False))
        elif args.command == "send-photo":
            print(json.dumps(send_photo(int(args.chat_id), args.photo, caption=args.caption, thread_id=args.thread_id), ensure_ascii=False))
        elif args.command == "get-offset":
            offset = read_offset()
            print(offset if offset is not None else "")
        elif args.command == "set-offset":
            STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
            STATE_FILE.write_text(str(args.offset), encoding="utf-8")
            print(args.offset)
    except DynamicCredentialError as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
