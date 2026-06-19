"""
claude_analysis.py - Claude-powered qualitative equity research for one ticker.

Part of the US Stock Screener. This is ADDITIVE: it does not touch the existing
screener, live-price, or detail pipelines. It calls the Anthropic Claude API and
returns a fresh, qualitative read on a stock - the kind of narrative a prospective
buyer wants - NOT chart metrics or moving averages.

Usage:
    python claude_analysis.py TICKER [--output result.json]
                              [--price 41.69] [--sector "Technology"]
                              [--market-cap "12.5B"] [--model claude-opus-4-8]
                              [--max-tokens 8000]

The API key is read from the ANTHROPIC_API_KEY environment variable. It is never
hardcoded and never written to disk.

Output: a JSON object with exactly these 7 research fields -
    investment_thesis        (string)
    fundamental_strengths    (list of strings)
    key_risks                (list of strings)
    near_term_catalysts      (string)
    valuation_narrative      (string)
    competitive_position     (string)
    market_sentiment         (string)
plus a little metadata (ticker, model, generated_at, usage). On any failure it
writes a clean error object {"error": true, "message": ..., "hint": ..., "raw": ...}
and exits non-zero, so the UI can show a readable message.

NOTE: this file is intentionally pure ASCII so it stays portable alongside the
PowerShell UI (which is read as ANSI on Windows PowerShell 5.1).
"""

import os
import re
import sys
import json
import argparse
import datetime


# ----------------------------------------------------------------------------
# Model. Verified current as of the build of this feature. Model IDs change over
# time - if you get a 404 "not found" on the model, update this string (or pass
# --model). claude-sonnet-4-6 is a cheaper alternative; see INTEGRATION_GUIDE.md.
# ----------------------------------------------------------------------------
MODEL = "claude-opus-4-8"
MAX_TOKENS = 8000

# ----------------------------------------------------------------------------
# Optional PROXY mode. If a proxy URL is configured, the app calls your proxy
# (e.g. the Wix Velo function in wix-proxy/) instead of Anthropic directly, so the
# Anthropic API key never ships to customers - only a revocable app token does.
# Resolution order: --proxy-url / --app-token, then STOCK_PROXY_URL /
# STOCK_APP_TOKEN env vars, then these embedded defaults. Leave blank to use the
# direct path (the user's own ANTHROPIC_API_KEY). See wix-proxy/DEPLOY.md.
# Do NOT commit a real token here - only paste into a distributed build.
# ----------------------------------------------------------------------------
EMBEDDED_PROXY_URL = ""
EMBEDDED_APP_TOKEN = ""

STRING_FIELDS = [
    "investment_thesis",
    "near_term_catalysts",
    "valuation_narrative",
    "competitive_position",
    "market_sentiment",
]
LIST_FIELDS = [
    "fundamental_strengths",
    "key_risks",
]

# JSON schema for structured outputs. Forces exactly the 7 fields, all required,
# no extras. (additionalProperties must be False for structured outputs.)
SCHEMA = {
    "type": "object",
    "properties": {
        "investment_thesis": {"type": "string"},
        "fundamental_strengths": {"type": "array", "items": {"type": "string"}},
        "key_risks": {"type": "array", "items": {"type": "string"}},
        "near_term_catalysts": {"type": "string"},
        "valuation_narrative": {"type": "string"},
        "competitive_position": {"type": "string"},
        "market_sentiment": {"type": "string"},
    },
    "required": [
        "investment_thesis", "fundamental_strengths", "key_risks",
        "near_term_catalysts", "valuation_narrative", "competitive_position",
        "market_sentiment",
    ],
    "additionalProperties": False,
}

SYSTEM_PROMPT = (
    "You are a seasoned fundamental equity research analyst writing for a "
    "prospective buyer of a US-listed stock. Your job is a clear, balanced, "
    "qualitative read on the business: the investment thesis, the real strengths, "
    "the real risks, near-term catalysts, a plain-English valuation narrative, "
    "the competitive position, and how the market currently perceives the name.\n\n"
    "Hard rules:\n"
    "- Use only facts you actually know. Do NOT fabricate revenue, margins, growth "
    "rates, price targets, or any specific numbers you are not confident are "
    "correct. Describe direction and magnitude qualitatively (for example "
    "'high-margin but decelerating growth') rather than inventing precise figures.\n"
    "- Acknowledge uncertainty explicitly. If you are not sure a detail is current "
    "or correct, say so plainly.\n"
    "- Your knowledge has a training cutoff and may be stale. Do not present "
    "possibly-outdated information as live fact. Avoid stating a current price or "
    "quarter-specific numbers unless the user provided them.\n"
    "- Do not give technical-analysis or chart metrics (no moving averages, RSI, "
    "support/resistance). This is fundamental, qualitative research.\n"
    "- Be balanced: give genuine risks, not just the bull case.\n"
    "- This is research for consideration, not personalized investment advice.\n"
    "- Write in clear, professional prose. Each list item should be a complete, "
    "self-contained point."
)


def _now():
    return datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def parse_args():
    p = argparse.ArgumentParser(
        description="Claude-powered qualitative stock analysis.")
    p.add_argument("ticker", help="Stock ticker, e.g. AAPL")
    p.add_argument("--output", default="",
                   help="Write the JSON result here (otherwise stdout).")
    p.add_argument("--price", default="", help="Optional recent price for context.")
    p.add_argument("--sector", default="", help="Optional sector for context.")
    p.add_argument("--market-cap", dest="market_cap", default="",
                   help="Optional market cap for context.")
    p.add_argument("--model", default=MODEL, help="Override the Claude model id.")
    p.add_argument("--max-tokens", dest="max_tokens", type=int, default=MAX_TOKENS,
                   help="Max response tokens.")
    p.add_argument("--proxy-url", dest="proxy_url", default="",
                   help="If set, call this proxy endpoint instead of Anthropic directly.")
    p.add_argument("--app-token", dest="app_token", default="",
                   help="Shared token sent to the proxy (x-app-token header).")
    return p.parse_args()


def build_user_prompt(ticker, price, sector, market_cap):
    lines = []
    lines.append(
        "Provide fundamental, qualitative equity research on the US-listed stock "
        "with ticker " + ticker.upper() + ".")
    ctx = []
    if price:
        ctx.append("approximate recent price: " + str(price))
    if sector:
        ctx.append("sector: " + str(sector))
    if market_cap:
        ctx.append("approximate market cap: " + str(market_cap))
    if ctx:
        lines.append(
            "Context provided by the user (approximate, may be stale): "
            + "; ".join(ctx) + ".")
    lines.append(
        "Focus on the business, its moat, growth drivers, risks, and how the "
        "market perceives it. Do not invent specific financial figures you are not "
        "confident about - speak qualitatively and flag uncertainty where it "
        "exists.")
    lines.append(
        "Return the analysis using the required JSON schema with these fields: "
        "investment_thesis, fundamental_strengths, key_risks, near_term_catalysts, "
        "valuation_narrative, competitive_position, market_sentiment.")
    return "\n".join(lines)


def strip_fences(text):
    """Remove a leading/trailing markdown code fence if present."""
    t = (text or "").strip()
    if t.startswith("```"):
        t = re.sub(r"^```[A-Za-z0-9_-]*[ \t]*\r?\n?", "", t)
        t = re.sub(r"\r?\n?```\s*$", "", t)
    return t.strip()


def normalize_fields(data):
    """Coerce the parsed object into exactly the 7 fields with safe types."""
    out = {}
    for f in STRING_FIELDS:
        v = data.get(f, "")
        out[f] = "" if v is None else str(v)
    for f in LIST_FIELDS:
        v = data.get(f, [])
        if isinstance(v, list):
            out[f] = [str(x) for x in v]
        elif v in (None, ""):
            out[f] = []
        else:
            out[f] = [str(v)]
    return out


def error_obj(message, hint="", raw=""):
    return {"error": True, "message": message, "hint": hint, "raw": raw}


def run_analysis(anthropic, args):
    """Call Claude and return either the 7-field result dict or an error_obj.
    API/transport exceptions are raised to the caller (typed handling there)."""
    client = anthropic.Anthropic()  # reads ANTHROPIC_API_KEY from the environment

    resp = client.messages.create(
        model=args.model,
        max_tokens=args.max_tokens,
        thinking={"type": "adaptive"},
        system=SYSTEM_PROMPT,
        messages=[{
            "role": "user",
            "content": build_user_prompt(
                args.ticker, args.price, args.sector, args.market_cap),
        }],
        output_config={
            "effort": "medium",
            "format": {"type": "json_schema", "schema": SCHEMA},
        },
    )

    if resp.stop_reason == "refusal":
        return error_obj(
            "Claude declined to analyze this ticker.",
            hint="Try a different ticker - this can happen for restricted topics.")

    # Collect the text block(s). With thinking on there is a thinking block first,
    # so do not assume content[0] is the answer.
    text = ""
    for block in resp.content:
        if getattr(block, "type", "") == "text":
            text += block.text

    if resp.stop_reason == "max_tokens":
        return error_obj(
            "The response was cut off (hit max_tokens).",
            hint="Increase --max-tokens (currently " + str(args.max_tokens) + ").",
            raw=text)

    cleaned = strip_fences(text)
    try:
        data = json.loads(cleaned)
    except Exception:
        return error_obj(
            "Could not parse the model response as JSON.",
            hint="This is usually transient - try again.",
            raw=text)

    out = normalize_fields(data)
    out["ticker"] = args.ticker.upper()
    out["model"] = getattr(resp, "model", args.model)
    out["generated_at"] = _now()
    try:
        out["usage"] = {
            "input_tokens": resp.usage.input_tokens,
            "output_tokens": resp.usage.output_tokens,
        }
    except Exception:
        pass
    return out


def run_via_proxy(proxy_url, app_token, args):
    """Call the server-side proxy instead of Anthropic. Returns the 7-field dict
    (the proxy returns the same shape) or a clean error_obj. No Anthropic key or
    SDK is needed on this machine."""
    try:
        import requests
    except ImportError:
        return error_obj(
            "The 'requests' package is not installed.",
            hint="Run: pip install requests")

    payload = {"ticker": args.ticker.upper()}
    if args.price:      payload["price"] = args.price
    if args.sector:     payload["sector"] = args.sector
    if args.market_cap: payload["market_cap"] = args.market_cap
    # Note: model is intentionally NOT sent - the proxy owner controls which model
    # runs (e.g. a fast model to stay under a host's execution limit).

    headers = {"Content-Type": "application/json"}
    if app_token:
        headers["x-app-token"] = app_token

    try:
        r = requests.post(proxy_url, json=payload, headers=headers, timeout=120)
    except Exception as e:
        return error_obj(
            "Could not reach the analysis proxy.",
            hint="Check STOCK_PROXY_URL and your network connection.",
            raw=str(e))

    try:
        data = r.json()
    except Exception:
        return error_obj(
            "The proxy did not return JSON (status " + str(r.status_code) + ").",
            hint="Check the proxy URL and that the Wix function is published.",
            raw=(r.text or "")[:2000])

    # If the proxy already returned a structured error, pass it through.
    if isinstance(data, dict) and data.get("error"):
        return data
    if r.status_code >= 400:
        return error_obj(
            "Proxy returned an error (status " + str(r.status_code) + ").",
            raw=json.dumps(data)[:2000])
    return data


def finish(obj, output_path, exit_code):
    """Write the JSON object (atomically) to the output path or stdout, then exit."""
    text = json.dumps(obj, indent=2)
    if output_path:
        try:
            tmp = output_path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(text)
            os.replace(tmp, output_path)
        except OSError as e:
            sys.stderr.write("Could not write output file: " + str(e) + "\n")
            sys.stdout.write(text + "\n")
    else:
        sys.stdout.write(text + "\n")
    sys.exit(exit_code)


def main():
    args = parse_args()

    # Proxy mode takes precedence if configured (no Anthropic key needed locally).
    proxy_url = args.proxy_url or os.environ.get("STOCK_PROXY_URL", "") or EMBEDDED_PROXY_URL
    app_token = args.app_token or os.environ.get("STOCK_APP_TOKEN", "") or EMBEDDED_APP_TOKEN
    if proxy_url:
        result = run_via_proxy(proxy_url, app_token, args)
        finish(result, args.output, 1 if (isinstance(result, dict) and result.get("error")) else 0)
        return

    if not os.environ.get("ANTHROPIC_API_KEY"):
        finish(error_obj(
            "ANTHROPIC_API_KEY is not set.",
            hint="Set the ANTHROPIC_API_KEY environment variable, then restart the "
                 "app (and the launching console). See INTEGRATION_GUIDE.md."),
            args.output, 1)

    try:
        import anthropic
    except ImportError:
        finish(error_obj(
            "The 'anthropic' Python package is not installed.",
            hint="Run: pip install anthropic"),
            args.output, 1)

    try:
        result = run_analysis(anthropic, args)
    except anthropic.AuthenticationError as e:
        result = error_obj(
            "Authentication failed - the API key was rejected.",
            hint="Check ANTHROPIC_API_KEY is a valid key from console.anthropic.com.",
            raw=str(e))
    except anthropic.RateLimitError as e:
        result = error_obj(
            "Rate limited by the Claude API.",
            hint="Wait a minute and try again, or check your plan limits.",
            raw=str(e))
    except anthropic.APIConnectionError as e:
        result = error_obj(
            "Could not reach the Claude API (network error).",
            hint="Check your internet connection, VPN, or firewall, then retry.",
            raw=str(e))
    except anthropic.APIStatusError as e:
        result = error_obj(
            "Claude API returned an error (status "
            + str(getattr(e, "status_code", "?")) + ").",
            hint="Retry if it is a 5xx server error. See the raw message below.",
            raw=str(e))
    except Exception as e:
        result = error_obj(
            "Unexpected error: " + type(e).__name__,
            raw=str(e))

    finish(result, args.output, 1 if result.get("error") else 0)


if __name__ == "__main__":
    main()
