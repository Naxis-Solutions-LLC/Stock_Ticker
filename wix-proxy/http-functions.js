// http-functions.js  --  Wix Velo proxy for the US Stock Screener "AI Research" tab
// =============================================================================
// Put this file in your site's backend, named EXACTLY  backend/http-functions.js
// (Backend & Public -> Backend). It exposes:
//   GET  https://<your-site>/_functions/ping     -> {"ok":true}  (health check)
//   POST https://<your-site>/_functions/analyze  -> 7-field research JSON
//
// Secrets Manager must contain two secrets (Developer Tools -> Secrets Manager):
//   ANTHROPIC_API_KEY  - your Anthropic key (sk-ant-...)
//   STOCK_APP_TOKEN    - any long random string; the app sends the same value
//
// Velo HTTP functions have a short execution limit, so this is tuned for speed
// (Haiku, small token cap, no extended thinking). If calls still time out, the
// proxy belongs on a host without that limit (e.g. a Cloudflare Worker).
// =============================================================================

import { ok, badRequest, forbidden, serverError } from 'wix-http-functions';
import { getSecret } from 'wix-secrets-backend';
import { fetch } from 'wix-fetch';

const MODEL = 'claude-haiku-4-5';
const MAX_TOKENS = 1200;
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

function jsonResponse(builder, obj) {
    return builder({ headers: { 'Content-Type': 'application/json' }, body: obj });
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

// Health check: GET /_functions/ping -> {"ok":true}
export function get_ping(request) {
    return jsonResponse(ok, { ok: true });
}

export async function post_analyze(request) {
    try {
        // 1. Shared-token auth so this is not an open relay.
        let expected = '';
        try { expected = await getSecret('STOCK_APP_TOKEN'); } catch (e) { expected = ''; }
        const provided = request.headers['x-app-token'] || '';
        if (!expected || provided !== expected) {
            return jsonResponse(forbidden, { error: true, message: 'Invalid or missing app token.' });
        }

        // 2. Parse input.
        let payload = {};
        try { payload = await request.body.json(); } catch (e) { payload = {}; }
        const ticker = (payload.ticker || '').toString().trim().toUpperCase();
        if (!ticker) {
            return jsonResponse(badRequest, { error: true, message: 'ticker is required.' });
        }

        // 3. Call Claude with the key from Secrets Manager.
        let apiKey = '';
        try { apiKey = await getSecret('ANTHROPIC_API_KEY'); } catch (e) { apiKey = ''; }
        if (!apiKey) {
            return jsonResponse(serverError, { error: true, message: 'Server is missing ANTHROPIC_API_KEY.' });
        }

        const reqBody = {
            model: (payload.model || MODEL),
            max_tokens: MAX_TOKENS,
            system: SYSTEM_PROMPT,
            messages: [{ role: 'user', content: buildUserPrompt(ticker, payload) }],
            output_config: { format: { type: 'json_schema', schema: SCHEMA } }
        };

        const httpResponse = await fetch(ANTHROPIC_URL, {
            method: 'post',
            headers: {
                'Content-Type': 'application/json',
                'x-api-key': apiKey,
                'anthropic-version': ANTHROPIC_VERSION
            },
            body: JSON.stringify(reqBody)
        });

        const data = await httpResponse.json();
        if (!httpResponse.ok) {
            return jsonResponse(serverError, {
                error: true,
                message: 'Anthropic API error (status ' + httpResponse.status + ').',
                raw: JSON.stringify(data).slice(0, 2000)
            });
        }
        if (data.stop_reason === 'refusal') {
            return jsonResponse(ok, { error: true, message: 'Claude declined to analyze this ticker.' });
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
            return jsonResponse(ok, { error: true, message: 'Could not parse model response as JSON.', raw: text.slice(0, 2000) });
        }

        parsed.ticker = ticker;
        parsed.model = data.model || reqBody.model;
        if (data.usage) {
            parsed.usage = { input_tokens: data.usage.input_tokens, output_tokens: data.usage.output_tokens };
        }
        return jsonResponse(ok, parsed);
    } catch (err) {
        return jsonResponse(serverError, { error: true, message: 'Proxy error: ' + String(err) });
    }
}
