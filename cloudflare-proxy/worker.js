// worker.js  --  Cloudflare Worker proxy for the US Stock Screener "AI Research" tab
// =============================================================================
// Why this exists: Wix Velo HTTP functions have a short execution limit (~14s)
// and a full Claude call can exceed it (intermittent 504s). A Cloudflare Worker
// waits on the Anthropic request without that limit, so it's reliable - and free.
//
// Same contract as the Wix proxy, so the desktop app needs no changes:
//   GET  <worker-url>/          -> {"ok":true}                (health check)
//   POST <worker-url>/  (or any path)  with header x-app-token, body {"ticker":"AAPL"}
//        -> the 7-field research JSON
//
// Secrets (set as encrypted Worker variables - see DEPLOY.md):
//   ANTHROPIC_API_KEY  - your Anthropic key (sk-ant-...)
//   STOCK_APP_TOKEN    - any long random string; the app sends the same value
//
// No execution-limit worries here, so this uses a higher-quality model than the
// Velo version. Change MODEL/MAX_TOKENS below to taste.
// =============================================================================

const MODEL = 'claude-sonnet-4-6';   // good quality/speed; 'claude-opus-4-8' for max quality
const MAX_TOKENS = 2000;
const ANTHROPIC_URL = 'https://api.anthropic.com/v1/messages';
const ANTHROPIC_VERSION = '2023-06-01';

const SYSTEM_PROMPT =
    'You are a seasoned fundamental equity research analyst writing for a ' +
    'prospective buyer of a US-listed stock. Give a clear, balanced, qualitative ' +
    'read on the business: investment thesis, real strengths, real risks, ' +
    'near-term catalysts, a plain-English valuation narrative, competitive ' +
    'position, and how the market currently perceives it.\n\n' +
    'Hard rules:\n' +
    '- Use only facts you actually know. Do NOT fabricate revenue, margins, growth ' +
    'rates, price targets, or any specific numbers you are not confident about. ' +
    'Describe direction and magnitude qualitatively rather than inventing figures.\n' +
    '- Acknowledge uncertainty explicitly. Your knowledge has a training cutoff and ' +
    'may be stale; do not present possibly-outdated info as live fact, and avoid ' +
    'current prices or quarter-specific numbers unless the user provided them.\n' +
    '- No technical-analysis or chart metrics. This is fundamental research.\n' +
    '- Be balanced (give genuine risks), and remember this is research for ' +
    'consideration, not personalized investment advice.';

const SCHEMA = {
    type: 'object',
    properties: {
        investment_thesis: { type: 'string' },
        fundamental_strengths: { type: 'array', items: { type: 'string' } },
        key_risks: { type: 'array', items: { type: 'string' } },
        near_term_catalysts: { type: 'string' },
        valuation_narrative: { type: 'string' },
        competitive_position: { type: 'string' },
        market_sentiment: { type: 'string' }
    },
    required: [
        'investment_thesis', 'fundamental_strengths', 'key_risks',
        'near_term_catalysts', 'valuation_narrative', 'competitive_position',
        'market_sentiment'
    ],
    additionalProperties: false
};

function json(obj, status) {
    return new Response(JSON.stringify(obj), {
        status: status || 200,
        headers: { 'Content-Type': 'application/json' }
    });
}

function buildUserPrompt(ticker, payload) {
    const lines = [];
    lines.push('Provide fundamental, qualitative equity research on the US-listed ' +
        'stock with ticker ' + ticker + '.');
    const ctx = [];
    if (payload.price) { ctx.push('approximate recent price: ' + payload.price); }
    if (payload.sector) { ctx.push('sector: ' + payload.sector); }
    if (payload.market_cap) { ctx.push('approximate market cap: ' + payload.market_cap); }
    if (ctx.length) {
        lines.push('Context provided by the user (approximate, may be stale): ' +
            ctx.join('; ') + '.');
    }
    lines.push('Return the analysis using the required JSON schema with these fields: ' +
        'investment_thesis, fundamental_strengths, key_risks, near_term_catalysts, ' +
        'valuation_narrative, competitive_position, market_sentiment.');
    return lines.join('\n');
}

export default {
    async fetch(request, env) {
        // Health check
        if (request.method === 'GET') {
            return json({ ok: true });
        }
        if (request.method !== 'POST') {
            return json({ error: true, message: 'Use POST.' }, 405);
        }

        // 1. Shared-token auth so this is not an open relay.
        const provided = request.headers.get('x-app-token') || '';
        if (!env.STOCK_APP_TOKEN || provided !== env.STOCK_APP_TOKEN) {
            return json({ error: true, message: 'Invalid or missing app token.' }, 403);
        }

        // 2. Parse input.
        let payload = {};
        try { payload = await request.json(); } catch (e) { payload = {}; }
        const ticker = (payload.ticker || '').toString().trim().toUpperCase();
        if (!ticker) {
            return json({ error: true, message: 'ticker is required.' }, 400);
        }
        if (!env.ANTHROPIC_API_KEY) {
            return json({ error: true, message: 'Server is missing ANTHROPIC_API_KEY.' }, 500);
        }

        // 3. Call Claude.
        const reqBody = {
            model: MODEL,
            max_tokens: MAX_TOKENS,
            system: SYSTEM_PROMPT,
            messages: [{ role: 'user', content: buildUserPrompt(ticker, payload) }],
            output_config: { format: { type: 'json_schema', schema: SCHEMA } }
        };

        let resp;
        try {
            resp = await fetch(ANTHROPIC_URL, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                    'x-api-key': env.ANTHROPIC_API_KEY,
                    'anthropic-version': ANTHROPIC_VERSION
                },
                body: JSON.stringify(reqBody)
            });
        } catch (e) {
            return json({ error: true, message: 'Could not reach Anthropic.', raw: String(e) }, 502);
        }

        const data = await resp.json();
        if (!resp.ok) {
            return json({
                error: true,
                message: 'Anthropic API error (status ' + resp.status + ').',
                raw: JSON.stringify(data).slice(0, 2000)
            }, 502);
        }
        if (data.stop_reason === 'refusal') {
            return json({ error: true, message: 'Claude declined to analyze this ticker.' });
        }

        // 4. Extract the JSON text block (skip any thinking block).
        let text = '';
        const content = data.content || [];
        for (let i = 0; i < content.length; i++) {
            if (content[i].type === 'text') { text += content[i].text; }
        }
        let parsed;
        try {
            parsed = JSON.parse(text);
        } catch (e) {
            return json({ error: true, message: 'Could not parse model response as JSON.', raw: text.slice(0, 2000) });
        }

        parsed.ticker = ticker;
        parsed.model = data.model || MODEL;
        if (data.usage) {
            parsed.usage = { input_tokens: data.usage.input_tokens, output_tokens: data.usage.output_tokens };
        }
        return json(parsed);
    }
};
