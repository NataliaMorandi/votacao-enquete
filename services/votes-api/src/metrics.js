'use strict';

const client = require('prom-client');

const register = new client.Registry();
client.collectDefaultMetrics({ register, prefix: 'votes_api_' });

const httpDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duração das requisições HTTP em segundos',
  labelNames: ['method', 'route', 'status'],
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5],
  registers: [register],
});

const votosAceitos = new client.Counter({
  name: 'votos_aceitos_total',
  help: 'Total de votos aceitos e publicados no SNS',
  registers: [register],
});

const enquetesCriadas = new client.Counter({
  name: 'enquetes_criadas_total',
  help: 'Total de enquetes criadas',
  registers: [register],
});

const enquetesEncerradas = new client.Counter({
  name: 'enquetes_encerradas_total',
  help: 'Total de enquetes encerradas (cron ou lazy)',
  registers: [register],
});

module.exports = { register, httpDuration, votosAceitos, enquetesCriadas, enquetesEncerradas };
