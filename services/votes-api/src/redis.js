'use strict';

const Redis = require('ioredis');
const logger = require('./logger');

/**
 * Redis é usado apenas para CONTADORES (leitura rápida do resultado).
 * A fonte de verdade continua sendo o Postgres — se o Redis cair,
 * a API reconta do banco (degradação elegante).
 */
const redis = new Redis(process.env.REDIS_URL || 'redis://redis:6379', {
  lazyConnect: false,
  maxRetriesPerRequest: 1,
  enableOfflineQueue: false,
  retryStrategy: (times) => Math.min(times * 200, 2_000),
});

redis.on('error', (err) => logger.warn('redis_error', { error: err.message }));
redis.on('ready', () => logger.info('redis_conectado'));

module.exports = { redis };
