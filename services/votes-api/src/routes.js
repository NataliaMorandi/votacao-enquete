'use strict';

const express = require('express');
const { randomUUID } = require('crypto');
const { pool } = require('./db');
const { redis } = require('./redis');
const { publish } = require('./sns');
const logger = require('./logger');
const { votosAceitos, enquetesCriadas, enquetesEncerradas } = require('./metrics');

const router = express.Router();

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// -----------------------------------------------------------------
// POST /enquetes — cria enquete (título, descrição, opções, prazo)
// -----------------------------------------------------------------
router.post('/enquetes', async (req, res, next) => {
  const {
    titulo,
    descricao = null,
    opcoes,
    duracao_minutos = 60,
    criada_por = null,
  } = req.body || {};

  if (typeof titulo !== 'string' || titulo.trim().length < 3) {
    return res.status(400).json({ error: 'titulo_invalido', detalhe: 'mínimo 3 caracteres' });
  }
  if (
    !Array.isArray(opcoes) ||
    opcoes.length < 2 ||
    opcoes.length > 10 ||
    opcoes.some((o) => typeof o !== 'string' || o.trim().length === 0)
  ) {
    return res.status(400).json({
      error: 'opcoes_invalidas',
      detalhe: 'informe de 2 a 10 opções não vazias',
    });
  }
  const minutos = Number(duracao_minutos);
  if (!Number.isInteger(minutos) || minutos < 1 || minutos > 10_080) {
    return res.status(400).json({ error: 'duracao_invalida', detalhe: 'entre 1 e 10080 minutos' });
  }

  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const { rows } = await client.query(
      `INSERT INTO enquetes (titulo, descricao, prazo, criada_por)
       VALUES ($1, $2, now() + ($3 || ' minutes')::interval, $4)
       RETURNING id, titulo, descricao, status, abertura, prazo, criada_por`,
      [titulo.trim(), descricao, String(minutos), criada_por]
    );
    const enquete = rows[0];

    const opcoesCriadas = [];
    for (let i = 0; i < opcoes.length; i++) {
      const r = await client.query(
        `INSERT INTO opcoes (enquete_id, rotulo, ordem)
         VALUES ($1, $2, $3)
         RETURNING id, rotulo, ordem`,
        [enquete.id, opcoes[i].trim(), i + 1]
      );
      opcoesCriadas.push(r.rows[0]);
    }
    await client.query('COMMIT');

    enquetesCriadas.inc();
    logger.info('enquete_criada', {
      enquete_id: enquete.id,
      total_opcoes: opcoesCriadas.length,
      duracao_minutos: minutos,
      prazo: enquete.prazo,
    });

    return res.status(201).json({ ...enquete, opcoes: opcoesCriadas });
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    return next(err);
  } finally {
    client.release();
  }
});

// -----------------------------------------------------------------
// GET /enquetes — lista as enquetes (para o front)
// -----------------------------------------------------------------
router.get('/enquetes', async (req, res, next) => {
  try {
    const { rows } = await pool.query(
      `SELECT e.id, e.titulo, e.descricao, e.status, e.abertura, e.prazo,
              (SELECT count(*) FROM votos v WHERE v.enquete_id = e.id)::int AS total_votos
         FROM enquetes e
        ORDER BY e.abertura DESC
        LIMIT 50`
    );
    return res.json({ enquetes: rows });
  } catch (err) {
    return next(err);
  }
});

// -----------------------------------------------------------------
// POST /enquetes/:id/votos — registra voto e publica evento no SNS
// -----------------------------------------------------------------
router.post('/enquetes/:id/votos', async (req, res, next) => {
  const { id } = req.params;
  const { cpf, opcao_id } = req.body || {};

  if (!UUID_RE.test(id)) return res.status(400).json({ error: 'id_invalido' });
  const cpfLimpo = String(cpf || '').replace(/\D/g, '');
  if (cpfLimpo.length !== 11) return res.status(400).json({ error: 'cpf_invalido' });
  if (!UUID_RE.test(String(opcao_id || ''))) {
    return res.status(400).json({ error: 'opcao_id_invalido' });
  }

  try {
    const { rows } = await pool.query(
      'SELECT id, status, prazo FROM enquetes WHERE id = $1',
      [id]
    );
    if (rows.length === 0) return res.status(404).json({ error: 'enquete_nao_encontrada' });

    const enquete = rows[0];
    if (enquete.status !== 'aberta') return res.status(409).json({ error: 'enquete_fechada' });
    if (new Date(enquete.prazo) <= new Date()) {
      return res.status(409).json({ error: 'enquete_expirada' });
    }

    const opcao = await pool.query(
      'SELECT id, rotulo FROM opcoes WHERE id = $1 AND enquete_id = $2',
      [opcao_id, id]
    );
    if (opcao.rows.length === 0) {
      return res.status(400).json({ error: 'opcao_nao_pertence_a_enquete' });
    }

    // ON CONFLICT garante 1 CPF por enquete sem risco de corrida
    const votoId = randomUUID();
    const ins = await pool.query(
      `INSERT INTO votos (id, enquete_id, opcao_id, cpf)
       VALUES ($1, $2, $3, $4)
       ON CONFLICT (enquete_id, cpf) DO NOTHING
       RETURNING id, criado_em`,
      [votoId, id, opcao_id, cpfLimpo]
    );
    if (ins.rows.length === 0) return res.status(409).json({ error: 'cpf_ja_votou' });

    votosAceitos.inc();

    // Publica o evento (o CPF NÃO vai no evento — minimização de dados)
    const evento = {
      voto_id: votoId,
      enquete_id: id,
      opcao_id,
      opcao_rotulo: opcao.rows[0].rotulo,
      registrado_em: ins.rows[0].criado_em,
    };
    let aviso = null;
    try {
      await publish('voto.registrado', evento, { enquete_id: id, opcao_id });
    } catch (err) {
      // O voto já está persistido: a falha do SNS não invalida o voto.
      logger.error('sns_publish_falhou', { voto_id: votoId, error: err.message });
      aviso = 'voto_salvo_mas_evento_nao_publicado';
    }

    logger.info('voto_registrado', {
      voto_id: votoId,
      enquete_id: id,
      opcao_id,
      opcao_rotulo: opcao.rows[0].rotulo,
    });

    return res.status(201).json({ ...evento, ...(aviso ? { aviso } : {}) });
  } catch (err) {
    return next(err);
  }
});

// -----------------------------------------------------------------
// GET /enquetes/:id/resultado — contadores do Redis (fallback Postgres)
// -----------------------------------------------------------------
async function contarNoBanco(enqueteId) {
  const { rows } = await pool.query(
    `SELECT o.id AS opcao_id, o.rotulo, o.ordem, count(v.id)::int AS votos
       FROM opcoes o
       LEFT JOIN votos v ON v.opcao_id = o.id
      WHERE o.enquete_id = $1
      GROUP BY o.id, o.rotulo, o.ordem
      ORDER BY o.ordem`,
    [enqueteId]
  );
  return rows;
}

router.get('/enquetes/:id/resultado', async (req, res, next) => {
  const { id } = req.params;
  if (!UUID_RE.test(id)) return res.status(400).json({ error: 'id_invalido' });

  try {
    const { rows } = await pool.query(
      'SELECT id, titulo, descricao, status, abertura, prazo FROM enquetes WHERE id = $1',
      [id]
    );
    if (rows.length === 0) return res.status(404).json({ error: 'enquete_nao_encontrada' });
    const enquete = rows[0];

    const opcoes = await pool.query(
      'SELECT id, rotulo, ordem FROM opcoes WHERE enquete_id = $1 ORDER BY ordem',
      [id]
    );

    let contagens = null;
    let fonte = 'redis';
    try {
      const chaves = opcoes.rows.map((o) => `enquete:${id}:opcao:${o.id}`);
      const valores = await redis.mget(chaves);
      const total = valores.reduce((acc, v) => acc + Number(v || 0), 0);

      if (total === 0) {
        // Redis vazio (cold start / restart) → reconta do Postgres e repopula
        fonte = 'postgres';
        contagens = await contarNoBanco(id);
      } else {
        contagens = opcoes.rows.map((o, i) => ({
          opcao_id: o.id,
          rotulo: o.rotulo,
          ordem: o.ordem,
          votos: Number(valores[i] || 0),
        }));
      }
    } catch (err) {
      logger.warn('redis_indisponivel_recontando', { enquete_id: id, error: err.message });
      fonte = 'postgres_fallback';
      contagens = await contarNoBanco(id);
    }

    const totalVotos = contagens.reduce((acc, c) => acc + Number(c.votos), 0);
    const resultado = contagens.map((c) => ({
      opcao_id: c.opcao_id,
      rotulo: c.rotulo,
      votos: Number(c.votos),
      percentual: totalVotos === 0 ? 0 : Number(((c.votos / totalVotos) * 100).toFixed(2)),
    }));

    return res.json({
      enquete_id: enquete.id,
      titulo: enquete.titulo,
      descricao: enquete.descricao,
      status: enquete.status,
      abertura: enquete.abertura,
      prazo: enquete.prazo,
      total_votos: totalVotos,
      fonte_contagem: fonte,
      resultado,
    });
  } catch (err) {
    return next(err);
  }
});

// -----------------------------------------------------------------
// POST /internal/close-expired — chamado pela Lambda (EventBridge cron)
// -----------------------------------------------------------------
router.post('/internal/close-expired', async (req, res, next) => {
  const token = req.header('x-internal-token');
  if (!process.env.INTERNAL_TOKEN || token !== process.env.INTERNAL_TOKEN) {
    return res.status(401).json({ error: 'token_invalido' });
  }

  try {
    const { rows } = await pool.query(
      `SELECT id FROM enquetes
        WHERE status = 'aberta' AND prazo <= now()
        ORDER BY prazo
        LIMIT 100`
    );

    const encerradas = [];
    for (const { id } of rows) {
      const upd = await pool.query(
        `UPDATE enquetes SET status = 'fechada'
          WHERE id = $1 AND status = 'aberta'
          RETURNING id, titulo`,
        [id]
      );
      if (upd.rows.length === 0) continue; // outra execução já fechou

      const contagens = await contarNoBanco(id);
      const total = contagens.reduce((acc, c) => acc + Number(c.votos), 0);

      try {
        await publish(
          'enquete.encerrada',
          {
            enquete_id: id,
            titulo: upd.rows[0].titulo,
            total_votos: total,
            resultado: contagens.map((c) => ({
              opcao_id: c.opcao_id,
              rotulo: c.rotulo,
              votos: Number(c.votos),
            })),
          },
          { enquete_id: id }
        );
      } catch (err) {
        // O encerramento já está persistido; a falha do SNS não o desfaz.
        logger.error('sns_publish_falhou_enquete_encerrada', {
          enquete_id: id,
          error: err.message,
        });
      }

      enquetesEncerradas.inc();
      encerradas.push(id);
      logger.info('enquete_encerrada', { enquete_id: id, total_votos: total });
    }

    return res.json({ encerradas: encerradas.length, ids: encerradas });
  } catch (err) {
    return next(err);
  }
});

module.exports = router;
