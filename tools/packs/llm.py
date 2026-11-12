# Thin wrapper: Claude Haiku 5.5 with JSON-schema output, usage ledger, retries.
import json, os, threading, time
from pathlib import Path
import anthropic

MODEL = "claude-haiku-5-5"
PRICE_IN, PRICE_OUT = 0.10 / 1e6, 0.50 / 1e6   # USD per token, prompts <= 100K tokens
LEDGER = Path(__file__).resolve().parent.parent / "ledger.jsonl"
_lock = threading.Lock()

_key = Path(os.path.expanduser("~/.config/couchsubs/anthropic-key")).read_text().strip()
client = anthropic.Anthropic(api_key=_key, max_retries=5, timeout=600)


def spent():
    if not LEDGER.exists():
        return 0.0
    return sum(json.loads(l)["usd"] for l in LEDGER.read_text().splitlines() if l.strip())


def call(system, user, schema, tag, max_tokens=32000, effort="medium"):
    for attempt in range(4):
        try:
            with client.messages.stream(
                model=MODEL,
                max_tokens=max_tokens,
                system=system,
                messages=[{"role": "user", "content": user}],
                output_config={"effort": effort, "format": {"type": "json_schema", "schema": schema}},
            ) as stream:
                msg = stream.get_final_message()
        except (anthropic.RateLimitError, anthropic.APIConnectionError, anthropic.InternalServerError) as e:
            time.sleep(10 * (attempt + 1))
            continue
        u = msg.usage
        usd = (u.input_tokens + (u.cache_creation_input_tokens or 0) + (u.cache_read_input_tokens or 0)) * PRICE_IN \
            + u.output_tokens * PRICE_OUT
        with _lock, LEDGER.open("a") as f:
            f.write(json.dumps({"tag": tag, "in": u.input_tokens, "out": u.output_tokens, "usd": usd,
                                "stop": msg.stop_reason}) + "\n")
        if msg.stop_reason == "refusal":
            return None
        text = next((b.text for b in msg.content if b.type == "text"), None)
        if not text:
            continue
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            continue
    return None
