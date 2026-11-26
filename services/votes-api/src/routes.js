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
const SLUG_RE = /^[a-z0-9]+(-[a-z0-9]+)*$/;

/** "Onde vamos almoçar?" -> "onde-vamos-almocar" */
function slugify(texto) {
  const base = String(texto)
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '') // remove acentos
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 60)
    .replace(/-+$/g, '');
  return base || 'enquete';
}

/** Garante slug único acrescentando -2, -3, ... */
async function slugUnico(client, base) {
  let candidato = base;
  for (let i = 2; i <= 50; i++) {
    const { rowCount } = await client.query('SELECT 1 FROM enquetes WHERE slug = $1', [candidato]);
    if (rowCount === 0) return candidato;
    candidato = `${base.slice(0, 55)}-${i}`;
  }
  return `${base.slice(0, 45)}-${randomUUID().slice(0, 8)}`;
}

/** Aceita uuid OU slug e devolve a enquete */
async function buscarEnquete(chave) {
  const sql = UUID_RE.test(chave)
    ? `SELECT id, slug, titulo, descricao, status, abertura, prazo, anonima, max_escolhas
         FROM enquetes WHERE id = $1`
    : `SELECT id, slug, titulo, descricao, status, abertura, prazo, anonima, max_escolhas
         FROM enquetes WHERE slug = $1`;
  const { rows } = await pool.query(sql, [chave]);
  return rows[0] || null;
}

// -----------------------------------------------------------------
// POST /enquetes — cria enquete
//   body: { titulo, descricao?, opcoes[], duracao_minutos?, criada_por?,
//           anonima?: boolean (default true),
//           max_escolhas?: 1|2 (default 1) }
// -----------------------------------------------------------------
router.post('/enquetes', async (req, res, next) => {
  const {
    titulo,
    descricao = null,
    opcoes,
    duracao_minutos = 60,
    criada_por = null,
    anonima = true,
    max_escolhas = 1,
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
  const maxEscolhas = Number(max_escolhas);
  if (![1, 2].includes(maxEscolhas)) {
    return res.status(400).json({ error: 'max_escolhas_invalido', detalhe: 'use 1 ou 2' });
  }
  const ehAnonima = anonima === undefined ? true : Boolean(anonima);

  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const base = slugify(titulo);
    let enquete = null;
    for (let tentativa = 1; tentativa <= 4 && !enquete; tentativa++) {
      const slug = tentativa === 1
        ? await slugUnico(client, base)
        : `${base.slice(0, 50)}-${randomUUID().slice(0, 6)}`;
      try {
        const { rows } = await client.query(
          `INSERT INTO enquetes (titulo, slug, descricao, prazo, criada_por, anonima, max_escolhas)
           VALUES ($1, $2, $3, now() + ($4 || ' minutes')::interval, $5, $6, $7)
           RETURNING id, slug, titulo, descricao, status, abertura, prazo, criada_por, anonima, max_escolhas`,
          [titulo.trim(), slug, descricao, String(minutos), criada_por, ehAnonima, maxEscolhas]
        );
        enquete = rows[0];
      } catch (err) {
        // corrida de slug: tenta de novo com sufixo aleatório
        if (err.code === '23505' && String(err.constraint || '').includes('slug')) continue;
        throw err;
      }
    }
    if (!enquete) throw new Error('nao_foi_possivel_gerar_slug');

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
      anonima: enquete.anonima,
      max_escolhas: enquete.max_escolhas,
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
      `SELECT e.id, e.slug, e.titulo, e.descricao, e.status, e.abertura, e.prazo,
              e.anonima, e.max_escolhas,
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
// POST /enquetes/:id/votos — registra 1 ou 2 votos e publica no SNS
//   body: { votante_id: uuid, nome?: string, opcao_ids: [uuid, ...] }
// -----------------------------------------------------------------
router.post('/enquetes/:chave/votos', async (req, res, next) => {
  const { chave } = req.params;
  const { votante_id, nome = null, opcao_ids } = req.body || {};

  if (!UUID_RE.test(chave) && !SLUG_RE.test(chave)) {
    return res.status(400).json({ error: 'id_invalido' });
  }
  if (!UUID_RE.test(String(votante_id || ''))) {
    return res.status(400).json({ error: 'votante_id_invalido' });
  }

  const lista = Array.isArray(opcao_ids) ? [...new Set(opcao_ids.map(String))] : [];
  if (lista.length === 0) {
    return res.status(400).json({ error: 'opcao_ids_invalido', detalhe: 'envie um array com as opções' });
  }
  if (lista.some((o) => !UUID_RE.test(o))) {
    return res.status(400).json({ error: 'opcao_ids_invalido', detalhe: 'uuid inválido' });
  }

  try {
    const encontrada = await buscarEnquete(chave);
    if (!encontrada) return res.status(404).json({ error: 'enquete_nao_encontrada' });

    const enquete = encontrada;
    const id = enquete.id;
    if (enquete.status !== 'aberta') return res.status(409).json({ error: 'enquete_fechada' });
    if (new Date(enquete.prazo) <= new Date()) {
      return res.status(409).json({ error: 'enquete_expirada' });
    }
    if (lista.length > enquete.max_escolhas) {
      return res.status(400).json({
        error: 'limite_de_escolhas_excedido',
        detalhe: `esta enquete permite até ${enquete.max_escolhas} opção(ões)`,
      });
    }

    let nomeLimpo = null;
    if (!enquete.anonima) {
      if (typeof nome !== 'string' || nome.trim().length < 2 || nome.trim().length > 80) {
        return res.status(400).json({ error: 'nome_obrigatorio', detalhe: 'informe seu nome (2 a 80 caracteres)' });
      }
      nomeLimpo = nome.trim();
    }

    // Todas as opções precisam pertencer a esta enquete
    const opcoesValidas = await pool.query(
      'SELECT id, rotulo FROM opcoes WHERE enquete_id = $1 AND id = ANY($2::uuid[])',
      [id, lista]
    );
    if (opcoesValidas.rows.length !== lista.length) {
      return res.status(400).json({ error: 'opcao_nao_pertence_a_enquete' });
    }
    const rotuloPorId = new Map(opcoesValidas.rows.map((o) => [o.id, o.rotulo]));

    const client = await pool.connect();
    let votosCriados = [];
    try {
      await client.query('BEGIN');

      // Serializa votos do MESMO votante nesta enquete (evita corrida de duplo clique)
      await client.query('SELECT pg_advisory_xact_lock(hashtext($1))', [`${id}:${votante_id}`]);

      const ja = await client.query(
        'SELECT count(DISTINCT opcao_id)::int AS n FROM votos WHERE enquete_id = $1 AND votante_id = $2',
        [id, votante_id]
      );
      if (ja.rows[0].n + lista.length > enquete.max_escolhas) {
        await client.query('ROLLBACK');
        return res.status(409).json({
          error: 'limite_de_escolhas_excedido',
          detalhe: `você já registrou ${ja.rows[0].n} voto(s); esta enquete permite ${enquete.max_escolhas}`,
        });
      }

      const valores = [];
      const placeholders = lista.map((opcaoId, i) => {
        const votoId = randomUUID();
        valores.push(votoId, id, opcaoId, votante_id, nomeLimpo);
        votosCriados.push({ voto_id: votoId, opcao_id: opcaoId });
        const b = i * 5;
        return `($${b + 1}, $${b + 2}, $${b + 3}, $${b + 4}, $${b + 5})`;
      });

      await client.query(
        `INSERT INTO votos (id, enquete_id, opcao_id, votante_id, votante_nome)
         VALUES ${placeholders.join(', ')}`,
        valores
      );

      await client.query('COMMIT');
    } catch (err) {
      await client.query('ROLLBACK').catch(() => {});
      if (err.code === '23505') {
        return res.status(409).json({ error: 'voto_duplicado', detalhe: 'você já votou nesta opção' });
      }
      throw err;
    } finally {
      client.release();
    }

    votosAceitos.inc(votosCriados.length);

    // Publica um evento por opção votada (o worker incrementa cada contador)
    let aviso = null;
    for (const v of votosCriados) {
      try {
        await publish(
          'voto.registrado',
          {
            voto_id: v.voto_id,
            enquete_id: id,
            opcao_id: v.opcao_id,
            opcao_rotulo: rotuloPorId.get(v.opcao_id),
            anonima: enquete.anonima,
          },
          { enquete_id: id, opcao_id: v.opcao_id }
        );
      } catch (err) {
        logger.error('sns_publish_falhou', { voto_id: v.voto_id, error: err.message });
        aviso = 'voto_salvo_mas_evento_nao_publicado';
      }
    }

    logger.info('voto_registrado', {
      enquete_id: id,
      enquete_slug: enquete.slug,
      total_opcoes: votosCriados.length,
      anonima: enquete.anonima,
      votante_nome: nomeLimpo,
    });

    return res.status(201).json({
      enquete_id: id,
      votos: votosCriados.map((v) => ({
        voto_id: v.voto_id,
        opcao_id: v.opcao_id,
        opcao_rotulo: rotuloPorId.get(v.opcao_id),
      })),
      ...(aviso ? { aviso } : {}),
    });
  } catch (err) {
    return next(err);
  }
});

// -----------------------------------------------------------------
// GET /enquetes/:id/resultado
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

router.get('/enquetes/:chave/resultado', async (req, res, next) => {
  const { chave } = req.params;
  if (!UUID_RE.test(chave) && !SLUG_RE.test(chave)) {
    return res.status(400).json({ error: 'id_invalido' });
  }

  try {
    const encontrada = await buscarEnquete(chave);
    if (!encontrada) return res.status(404).json({ error: 'enquete_nao_encontrada' });
    const enquete = encontrada;
    const id = enquete.id;

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

    // Em enquetes identificadas, mostra quem já votou (e em quê)
    let votantes = [];
    if (!enquete.anonima) {
      const { rows: linhas } = await pool.query(
        `SELECT v.votante_nome AS nome,
                array_agg(DISTINCT o.rotulo) AS opcoes
           FROM votos v
           JOIN opcoes o ON o.id = v.opcao_id
          WHERE v.enquete_id = $1 AND v.votante_nome IS NOT NULL
          GROUP BY v.votante_nome
          ORDER BY v.votante_nome`,
        [id]
      );
      votantes = linhas.map((l) => ({ nome: l.nome, opcoes: l.opcoes }));
    }

    return res.json({
      enquete_id: enquete.id,
      slug: enquete.slug,
      titulo: enquete.titulo,
      descricao: enquete.descricao,
      status: enquete.status,
      anonima: enquete.anonima,
      max_escolhas: enquete.max_escolhas,
      abertura: enquete.abertura,
      prazo: enquete.prazo,
      total_votos: totalVotos,
      fonte_contagem: fonte,
      resultado,
      votantes,
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
      if (upd.rows.length === 0) continue;

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
        logger.error('sns_publish_falhou_enquete_encerrada', { enquete_id: id, error: err.message });
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
