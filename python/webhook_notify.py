#!/usr/bin/env python3
"""Send a deploy/job/alert notification to Slack, Microsoft Teams, Discord or
any JSON webhook - from cron, CI or the tail end of a shell script.

The webhook flavour is detected from the URL, so the same call works whichever
chat tool a team happens to use. Long text (typically piped log output) is cut
from the front, because the error is almost always at the end.

The webhook URL is a credential. Pass it via $WEBHOOK_URL rather than the
command line where possible; it is never printed, including in errors and
--dry-run output.

Usage:
    webhook_notify.py [options] --title TITLE [--text TEXT | --text -]

Options:
    -u, --url URL         webhook URL (default: $WEBHOOK_URL)
    -k, --kind KIND       slack | teams | discord | generic (default: auto)
    -t, --title TEXT      headline (required)
    -m, --text TEXT       body; "-" reads stdin
    -s, --severity LEVEL  info | ok | warning | critical (default: info)
    -f, --field K=V       extra key/value line, repeatable (e.g. env=prod)
    -l, --link URL        "open" link, e.g. the CI run or runbook
    --code                render the body as a preformatted block (logs)
    --max-chars N         keep at most the last N chars of the body (default 3000)
    --no-context          don't add host and timestamp fields
    --timeout SEC         per-request timeout (default 10)
    --retries N           retries on network errors, 429 and 5xx (default 3)
    -n, --dry-run         print the JSON payload instead of sending it

Auto-detection:
    hooks.slack.com                          slack
    *.webhook.office.com, *.logic.azure.com,
    *.powerplatform.com                      teams (Adaptive Card; works with
                                             Workflows-based webhooks)
    discord.com/api/webhooks                 discord
    anything else                            generic flat JSON

Examples:
    export WEBHOOK_URL=https://hooks.slack.com/services/T000/B000/XXXX
    webhook_notify.py -t "Deploy finished" -s ok -f env=prod -f version=1.4.2 \\
        -l "https://ci.example.com/run/123"

    ./nightly-backup.sh 2>&1 | tail -n 50 | \\
        webhook_notify.py -t "Backup failed on $(hostname)" -s critical --code -m -

    webhook_notify.py -k teams -t "Disk at 91%" -s warning -m "/var on db01" --dry-run

Exit codes:
    0  delivered (or printed, with --dry-run)
    1  delivery failed after retries, or rejected by the endpoint
    2  bad usage
"""

import argparse
import datetime as dt
import json
import os
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

SEVERITIES = {
    # name: (hex colour, Teams Adaptive Card colour, emoji-free prefix)
    "info": ("#439FE0", "Accent", "INFO"),
    "ok": ("#2EB67D", "Good", "OK"),
    "warning": ("#ECB22E", "Warning", "WARNING"),
    "critical": ("#E01E5A", "Attention", "CRITICAL"),
}
RETRY_STATUS = {408, 425, 429, 500, 502, 503, 504}
MAX_BACKOFF = 30


class DeliveryError(Exception):
    pass


def detect_kind(url):
    parsed = urllib.parse.urlparse(url)
    host = (parsed.hostname or "").lower()
    if host == "hooks.slack.com":
        return "slack"
    if host.endswith((".webhook.office.com", ".logic.azure.com", ".powerplatform.com")):
        return "teams"
    if host in ("discord.com", "discordapp.com") and parsed.path.startswith("/api/webhooks"):
        return "discord"
    return "generic"


def redact(url):
    """scheme://host/... - enough to tell which endpoint, nothing usable."""
    parsed = urllib.parse.urlparse(url)
    return f"{parsed.scheme}://{parsed.hostname or '?'}/..."


def truncate_tail(text, limit):
    if limit <= 0 or len(text) <= limit:
        return text
    marker = f"[... {len(text) - limit} chars truncated ...]\n"
    return marker + text[-limit:]


def parse_fields(raw):
    fields = []
    for item in raw:
        key, sep, value = item.partition("=")
        if not sep or not key.strip():
            raise ValueError(f"--field expects KEY=VALUE, got {item!r}")
        fields.append((key.strip(), value.strip()))
    return fields


# --- payload builders -------------------------------------------------------

def slack_payload(msg):
    colour, _, prefix = SEVERITIES[msg["severity"]]
    body = msg["text"]
    if body and msg["code"]:
        body = "```" + body.replace("```", "'''") + "```"
    blocks = [{"type": "section", "text": {"type": "mrkdwn", "text": f"*{msg['title']}*"}}]
    if body:
        # Slack caps a section text at 3000 chars
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": body[:3000]}})
    if msg["fields"]:
        # ...and a section at 10 fields
        for i in range(0, len(msg["fields"]), 10):
            chunk = msg["fields"][i:i + 10]
            blocks.append({
                "type": "section",
                "fields": [{"type": "mrkdwn", "text": f"*{k}*\n{v}"} for k, v in chunk],
            })
    if msg["link"]:
        blocks.append({"type": "actions", "elements": [
            {"type": "button", "text": {"type": "plain_text", "text": "Open"}, "url": msg["link"]}
        ]})
    return {
        "text": f"[{prefix}] {msg['title']}",  # notification/fallback text
        "attachments": [{"color": colour, "blocks": blocks}],
    }


def teams_payload(msg):
    _, card_colour, prefix = SEVERITIES[msg["severity"]]
    body = [{
        "type": "TextBlock", "size": "Medium", "weight": "Bolder", "wrap": True,
        "color": card_colour, "text": f"{prefix}: {msg['title']}",
    }]
    if msg["text"]:
        block = {"type": "TextBlock", "wrap": True, "text": msg["text"]}
        if msg["code"]:
            block["fontType"] = "Monospace"
        body.append(block)
    if msg["fields"]:
        body.append({"type": "FactSet", "facts": [{"title": k, "value": v} for k, v in msg["fields"]]})
    card = {
        "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
        "type": "AdaptiveCard",
        "version": "1.4",
        "body": body,
    }
    if msg["link"]:
        card["actions"] = [{"type": "Action.OpenUrl", "title": "Open", "url": msg["link"]}]
    return {
        "type": "message",
        "attachments": [{
            "contentType": "application/vnd.microsoft.card.adaptive",
            "contentUrl": None,
            "content": card,
        }],
    }


def discord_payload(msg):
    colour, _, prefix = SEVERITIES[msg["severity"]]
    desc = msg["text"]
    if desc and msg["code"]:
        desc = "```\n" + desc.replace("```", "'''") + "\n```"
    embed = {
        "title": f"[{prefix}] {msg['title']}"[:256],
        "color": int(colour.lstrip("#"), 16),
        "description": desc[:4096] if desc else None,
        "fields": [{"name": k[:256], "value": (v or "-")[:1024], "inline": True}
                   for k, v in msg["fields"][:25]],
    }
    if msg["link"]:
        embed["url"] = msg["link"]
    # mentions in log output should never ping anyone
    return {"embeds": [{k: v for k, v in embed.items() if v}], "allowed_mentions": {"parse": []}}


def generic_payload(msg):
    return {
        "title": msg["title"],
        "text": msg["text"],
        "severity": msg["severity"],
        "fields": dict(msg["fields"]),
        "link": msg["link"],
    }


BUILDERS = {
    "slack": slack_payload,
    "teams": teams_payload,
    "discord": discord_payload,
    "generic": generic_payload,
}


# --- delivery ---------------------------------------------------------------

def retry_delay(attempt, retry_after=None):
    if retry_after:
        try:
            return min(float(retry_after), MAX_BACKOFF)
        except ValueError:
            pass
    return min(2 ** attempt, MAX_BACKOFF)


def post(url, payload, timeout, retries):
    data = json.dumps(payload).encode()
    target = redact(url)
    last = "no attempt made"
    for attempt in range(retries + 1):
        req = urllib.request.Request(
            url, data=data, method="POST",
            headers={"Content-Type": "application/json", "User-Agent": "webhook-notify/1.0"},
        )
        retry_after = None
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.status
        except urllib.error.HTTPError as exc:
            detail = exc.read(300).decode(errors="replace").strip()
            last = f"HTTP {exc.code} from {target}" + (f": {detail}" if detail else "")
            if exc.code not in RETRY_STATUS:
                raise DeliveryError(last) from None
            retry_after = exc.headers.get("Retry-After")
        except (urllib.error.URLError, socket.timeout, ConnectionError) as exc:
            reason = getattr(exc, "reason", exc)
            last = f"{target}: {reason}"
        if attempt < retries:
            delay = retry_delay(attempt, retry_after)
            print(f"webhook_notify: {last}; retrying in {delay:.0f}s", file=sys.stderr)
            time.sleep(delay)
    raise DeliveryError(f"giving up after {retries + 1} attempts: {last}")


def build_parser():
    p = argparse.ArgumentParser(
        description="Send a notification to Slack, Teams, Discord or a generic JSON webhook.",
        epilog="Exit codes: 0 delivered, 1 delivery failed, 2 usage error.",
    )
    p.add_argument("-u", "--url", default=os.environ.get("WEBHOOK_URL"))
    p.add_argument("-k", "--kind", choices=["auto", *BUILDERS], default="auto")
    p.add_argument("-t", "--title", required=True)
    p.add_argument("-m", "--text", default="")
    p.add_argument("-s", "--severity", choices=list(SEVERITIES), default="info")
    p.add_argument("-f", "--field", action="append", default=[], metavar="K=V")
    p.add_argument("-l", "--link")
    p.add_argument("--code", action="store_true")
    p.add_argument("--max-chars", type=int, default=3000)
    p.add_argument("--no-context", action="store_true")
    p.add_argument("--timeout", type=float, default=10)
    p.add_argument("--retries", type=int, default=3)
    p.add_argument("-n", "--dry-run", action="store_true")
    return p


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.retries < 0 or args.timeout <= 0:
        parser.error("--retries must be >= 0 and --timeout > 0")
    if not args.url and not (args.dry_run and args.kind != "auto"):
        parser.error("no webhook URL: pass --url or set WEBHOOK_URL")
    if args.url and urllib.parse.urlparse(args.url).scheme not in ("http", "https"):
        parser.error("webhook URL must be http(s)")
    if args.link and urllib.parse.urlparse(args.link).scheme not in ("http", "https"):
        parser.error("--link must be an http(s) URL")

    try:
        fields = parse_fields(args.field)
    except ValueError as exc:
        parser.error(str(exc))

    text = sys.stdin.read() if args.text == "-" else args.text
    text = truncate_tail(text.rstrip(), args.max_chars)

    if not args.no_context:
        now = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ")
        fields += [("host", socket.gethostname()), ("time", now)]

    kind = detect_kind(args.url) if args.kind == "auto" else args.kind
    msg = {
        "title": args.title.strip(),
        "text": text,
        "severity": args.severity,
        "fields": fields,
        "link": args.link,
        "code": args.code,
    }
    payload = BUILDERS[kind](msg)

    if args.dry_run:
        dest = redact(args.url) if args.url else "(no url)"
        print(f"# kind={kind} url={dest}", file=sys.stderr)
        print(json.dumps(payload, indent=2))
        return 0

    try:
        status = post(args.url, payload, args.timeout, args.retries)
    except DeliveryError as exc:
        print(f"webhook_notify: {exc}", file=sys.stderr)
        return 1
    print(f"webhook_notify: delivered to {kind} webhook (HTTP {status})", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
