'use strict';

const { Pool } = require('pg');
const logger = require('./logger');

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  max: 10,
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 5_000,
});

pool.on('error', (err) => logger.error('db_pool_error', { error: err.message }));

/**
 * Espera o Postgres ficar disponível (o container pode subir depois da API).
 */
async function waitForDb(retries = 30, delayMs = 2_000) {
  for (let i = 1; i <= retries; i++) {
    try {
      await pool.query('SELECT 1');
      logger.info('db_conectado', { tentativa: i });
      return;
    } catch (err) {
      logger.warn('db_indisponivel', { tentativa: i, error: err.message });
      await new Promise((r) => setTimeout(r, delayMs));
    }
  }
  throw new Error('Postgres indisponível após as tentativas');
}

module.exports = { pool, waitForDb };
