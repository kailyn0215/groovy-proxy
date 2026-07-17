#!/usr/bin/env node
/**
 * Minimal Node.js server that:
 *   1. Serves the static ChatGPT-esque frontend (public/)
 *   2. Proxies /api/* requests to a LiteLLM/OpenAI-compatible API
 *
 * No external dependencies — uses only Node built-ins.
 *
 * Env vars:
 *   PORT              - Port for this server (default 3000)
 *   LITELLM_BASE_URL  - (REQUIRED) API base URL, e.g. https://api.openai.com/v1
 *   LITELLM_API_KEY   - Optional API key forwarded as Authorization: Bearer ...
 */

const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const { URL } = require('url');

const PORT = parseInt(process.env.PORT || '3000', 10);
// Strip any trailing slash so we don't end up with `//v1/...`
const LITELLM_BASE_URL = (process.env.LITELLM_BASE_URL || '')
    .replace(/\/+$/, '');

if (!LITELLM_BASE_URL) {
    console.error('❌ ERROR: LITELLM_BASE_URL environment variable is required!');
    console.error('   Set it to your API endpoint, e.g.:');
    console.error('   - OpenAI: https://api.openai.com/v1');
    console.error('   - Azure: https://YOUR-RESOURCE.openai.azure.com/openai/deployments/YOUR-DEPLOYMENT');
    console.error('   - LiteLLM proxy: https://your-proxy-url.com');
    process.exit(1);
}
const LITELLM_API_KEY = process.env.LITELLM_API_KEY || '';

const PUBLIC_DIR = path.join(__dirname, 'public');

const MIME = {
    '.html': 'text/html; charset=utf-8',
    '.js':   'application/javascript; charset=utf-8',
    '.css':  'text/css; charset=utf-8',
    '.json': 'application/json; charset=utf-8',
    '.svg':  'image/svg+xml',
    '.png':  'image/png',
    '.ico':  'image/x-icon',
};

function serveStatic(req, res) {
    let urlPath = decodeURIComponent(req.url.split('?')[0]);
    if (urlPath === '/') urlPath = '/index.html';

    const filePath = path.join(PUBLIC_DIR, urlPath);
    if (!filePath.startsWith(PUBLIC_DIR)) {
        res.writeHead(403).end('Forbidden');
        return;
    }

    fs.readFile(filePath, (err, data) => {
        if (err) {
            res.writeHead(404, { 'Content-Type': 'text/plain' }).end('Not found');
            return;
        }
        const ext = path.extname(filePath).toLowerCase();
        res.writeHead(200, { 'Content-Type': MIME[ext] || 'application/octet-stream' });
        res.end(data);
    });
}

const API_PREFIX = '/api';
const HTTPS_DEFAULT_PORT = 443;
const HTTP_DEFAULT_PORT = 80;
const BAD_GATEWAY_STATUS = 502;

// Builds the upstream URL for a proxied request, e.g. /api/foo/bar -> {LITELLM_BASE_URL}/foo/bar
function buildUpstreamUrl(requestUrl) {
    const subPath = requestUrl.replace(new RegExp(`^${API_PREFIX}`), '');
    return new URL(LITELLM_BASE_URL + subPath);
}

// Prepares outbound request headers, stripping ones that would conflict with
// the upstream target and enforcing server-side auth/encoding rules.
function buildUpstreamHeaders(incomingHeaders, targetUrl) {
    const headers = { ...incomingHeaders };
    delete headers['host'];
    delete headers['content-length']; // will be recomputed by the HTTP client

    // Force identity encoding — Node won't auto-decompress, and we need to
    // stream SSE through untouched.
    headers['accept-encoding'] = 'identity';

    // Always override Authorization with our server-side key if set.
    // (The browser never sends one anyway.)
    if (LITELLM_API_KEY) {
        headers['authorization'] = `Bearer ${LITELLM_API_KEY}`;
    }

    // Make sure upstream sees the right Host header for TLS / vhost routing
    headers['host'] = targetUrl.host;

    return headers;
}

function buildUpstreamRequestOptions(req, targetUrl) {
    const defaultPort = targetUrl.protocol === 'https:' ? HTTPS_DEFAULT_PORT : HTTP_DEFAULT_PORT;

    return {
        method: req.method,
        hostname: targetUrl.hostname,
        port: targetUrl.port || defaultPort,
        path: targetUrl.pathname + targetUrl.search,
        headers: buildUpstreamHeaders(req.headers, targetUrl),
    };
}

// Relays the upstream response back to the client, stripping headers that
// would break chunked SSE forwarding.
function forwardUpstreamResponse(upstreamRes, res) {
    const outHeaders = { ...upstreamRes.headers };
    delete outHeaders['content-encoding'];
    delete outHeaders['content-length'];
    delete outHeaders['transfer-encoding'];
    // Keep the stream raw and uncompressed; disable proxy/Node buffering hints
    outHeaders['cache-control'] = 'no-cache, no-transform';
    outHeaders['x-accel-buffering'] = 'no';

    res.writeHead(upstreamRes.statusCode || BAD_GATEWAY_STATUS, outHeaders);
    upstreamRes.pipe(res);
}

function sendUpstreamError(res, targetUrl, method, err) {
    console.error(`Upstream error (${method} ${targetUrl.href}):`, err.message);
    if (res.headersSent) {
        res.end();
        return;
    }
    res.writeHead(BAD_GATEWAY_STATUS, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: { message: `Upstream error: ${err.message}` } }));
}

function proxyToLiteLLM(req, res) {
    const targetUrl = buildUpstreamUrl(req.url);
    const client = targetUrl.protocol === 'https:' ? https : http;
    const options = buildUpstreamRequestOptions(req, targetUrl);

    const upstream = client.request(options, (upstreamRes) => forwardUpstreamResponse(upstreamRes, res));
    upstream.on('error', (err) => sendUpstreamError(res, targetUrl, req.method, err));

    req.pipe(upstream);
}

const server = http.createServer((req, res) => {
    if (req.url.startsWith('/api/')) {
        proxyToLiteLLM(req, res);
    } else {
        serveStatic(req, res);
    }
});

server.listen(PORT, '0.0.0.0', () => {
    console.log(`\n🚀 UI running at  http://localhost:${PORT}`);
    console.log(`🔀 Proxying /api/* -> ${LITELLM_BASE_URL}`);
    if (LITELLM_API_KEY) {
        const masked = LITELLM_API_KEY.length > 8
            ? LITELLM_API_KEY.slice(0, 4) + '…' + LITELLM_API_KEY.slice(-4)
            : '****';
        console.log(`🔑 Using LITELLM_API_KEY=${masked}`);
    } else {
        console.log(`ℹ️  No LITELLM_API_KEY set — requests sent without Authorization header.`);
    }
    console.log('');
});
