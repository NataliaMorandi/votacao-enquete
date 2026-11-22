'use strict';

const express = require('express');
const path = require('path');
const logger = require('./logger');
const { pool, waitForDb } = require('./db');
const { register, httpDuration } = require('./metrics');
const routes = require('./routes');

const PORT = Number(process.env.PORT || 3000);

const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '64kb' }));

// --- Log de acesso estruturado + histograma de latência -----------
app.use((req, res, next) => {
  const inicio = process.hrtime.bigint();
  res.on('finish', () => {
    const ms = Number(process.hrtime.bigint() - inicio) / 1e6;
    const rota = req.route ? req.route.path : req.path;
    httpDuration.labels(req.method, rota, String(res.statusCode)).observe(ms / 1000);
    logger.info('http_request', {
      method: req.method,
      path: req.path,
      status: res.statusCode,
      duracao_ms: Math.round(ms),
    });
  });
  next();
});

// --- Health checks (usados pelos healthcheck do Docker) -----------
app.get('/health', (_req, res) => res.json({ status: 'ok', service: 'votes-api' }));

app.get('/health/ready', async (_req, res) => {
  try {
    await pool.query('SELECT 1');
    res.json({ status: 'ready' });
  } catch (err) {
    res.status(503).json({ status: 'not_ready', error: err.message });
  }
});

// --- Métricas Prometheus -----------------------------------------
app.get('/metrics', async (_req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

// --- Front-end estático (lista de enquetes) ----------------------
const PUBLIC_DIR = path.join(__dirname, '..', 'public');
app.use(express.static(PUBLIC_DIR, { index: 'index.html', extensions: ['html'] }));

// Página da enquete: /e/<id>
app.get('/e/:id', (_req, res) => res.sendFile(path.join(PUBLIC_DIR, 'enquete.html')));

// --- Rotas de negócio --------------------------------------------
app.use(routes);

app.use((_req, res) => res.status(404).json({ error: 'rota_nao_encontrada' }));

// eslint-disable-next-line no-unused-vars
app.use((err, _req, res, _next) => {
  logger.error('unhandled_error', { error: err.message, stack: err.stack });
  res.status(500).json({ error: 'internal_error' });
});

async function start() {
  await waitForDb();
  app.listen(PORT, '0.0.0.0', () => {
    logger.info('api_iniciada', { porta: PORT, node: process.version });
  });
}

start().catch((err) => {
  logger.error('falha_ao_iniciar', { error: err.message });
  process.exit(1);
});

// --- Shutdown gracioso -------------------------------------------
for (const sinal of ['SIGTERM', 'SIGINT']) {
  process.on(sinal, () => {
    logger.info('shutdown_solicitado', { sinal });
    pool.end().finally(() => process.exit(0));
  });
}
