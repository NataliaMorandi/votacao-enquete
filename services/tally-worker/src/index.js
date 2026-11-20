'use strict';

/**
 * tally-worker
 * ------------
 * Consumer da fila SQS alimentada pelo tópico SNS.
 *
 * Eventos tratados:
 *   - voto.registrado    -> incrementa o contador da opção no Redis
 *   - enquete.encerrada  -> marca a enquete como fechada no cache e loga o resultado
 *
 * Garantias:
 *   - At-least-once do SQS: o INCR é protegido por uma chave de idempotência
 *     (SET NX por voto_id), então reentrega não duplica contagem.
 *   - Falha no processamento => a mensagem NÃO é deletada e volta para a fila.
 */

const http = require('http');
const {
  SQSClient,
  ReceiveMessageCommand,
  DeleteMessageCommand,
} = require('@aws-sdk/client-sqs');
const Redis = require('ioredis');
const client = require('prom-client');
const logger = require('./logger');

const REGION = process.env.AWS_REGION;
const QUEUE_URL = process.env.SQS_QUEUE_URL;
const PORT = Number(process.env.METRICS_PORT || 9101);
const BATCH = 10;
const WAIT_SECONDS = 20;

if (!QUEUE_URL) {
  logger.error('config_ausente', { variavel: 'SQS_QUEUE_URL' });
  process.exit(1);
}

const sqs = new SQSClient({ region: REGION });
const redis = new Redis(process.env.REDIS_URL || 'redis://redis:6379', {
  maxRetriesPerRequest: null,
});
redis.on('error', (err) => logger.warn('redis_error', { error: err.message }));
redis.on('ready', () => logger.info('redis_conectado'));

// ------------------------- métricas ------------------------------
const register = new client.Registry();
client.collectDefaultMetrics({ register, prefix: 'tally_worker_' });

const recebidas = new client.Counter({
  name: 'sqs_mensagens_recebidas_total',
  help: 'Mensagens recebidas da fila SQS',
  registers: [register],
});

const votosProcessados = new client.Counter({
  name: 'votos_processados_total',
  help: 'Votos contabilizados por opção',
  labelNames: ['opcao_id'],
  registers: [register],
});

const duplicados = new client.Counter({
  name: 'votos_duplicados_ignorados_total',
  help: 'Reentregas ignoradas pela chave de idempotência',
  registers: [register],
});

const erros = new client.Counter({
  name: 'processamento_erros_total',
  help: 'Falhas ao processar mensagens',
  registers: [register],
});

// --------------------- servidor de métricas ----------------------
const server = http.createServer(async (req, res) => {
  if (req.url === '/health') {
    const pronto = redis.status === 'ready';
    res.writeHead(pronto ? 200 : 503, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: pronto ? 'ok' : 'degraded', redis: redis.status }));
    return;
  }
  if (req.url === '/metrics') {
    res.writeHead(200, { 'Content-Type': register.contentType });
    res.end(await register.metrics());
    return;
  }
  res.writeHead(404).end();
});
server.listen(PORT, '0.0.0.0', () => logger.info('metrics_server_iniciado', { porta: PORT }));

// ----------------------- processamento ---------------------------
async function processar(mensagem) {
  const body = JSON.parse(mensagem.Body);
  const tipo = body.tipo || 'desconhecido';

  if (tipo === 'voto.registrado') {
    const { voto_id, enquete_id, opcao_id, opcao_rotulo } = body;
    if (!voto_id || !enquete_id || !opcao_id) {
      throw new Error('evento_voto_incompleto');
    }

    // Idempotência: SQS entrega "pelo menos uma vez"
    const primeiro = await redis.set(`voto_processado:${voto_id}`, '1', 'EX', 86400, 'NX');
    if (primeiro !== 'OK') {
      duplicados.inc();
      logger.warn('voto_duplicado_ignorado', { voto_id, enquete_id });
      return;
    }

    await redis.incr(`enquete:${enquete_id}:opcao:${opcao_id}`);
    await redis.incr(`enquete:${enquete_id}:total`);
    votosProcessados.labels(opcao_id).inc();

    logger.info('voto_contabilizado', {
      voto_id,
      enquete_id,
      opcao_id,
      opcao_rotulo,
    });
    return;
  }

  if (tipo === 'enquete.encerrada') {
    const { enquete_id, total_votos, resultado } = body;
    await redis.set(`enquete:${enquete_id}:status`, 'fechada');
    logger.info('enquete_encerrada_processada', {
      enquete_id,
      total_votos,
      resultado,
    });
    return;
  }

  logger.warn('tipo_evento_desconhecido', { tipo, body });
}

// ------------------------- loop principal ------------------------
let rodando = true;

async function loop() {
  logger.info('worker_iniciado', { fila: QUEUE_URL, batch: BATCH, wait: WAIT_SECONDS });

  while (rodando) {
    try {
      const resp = await sqs.send(
        new ReceiveMessageCommand({
          QueueUrl: QUEUE_URL,
          MaxNumberOfMessages: BATCH,
          WaitTimeSeconds: WAIT_SECONDS,
          MessageAttributeNames: ['All'],
        })
      );

      const mensagens = resp.Messages || [];
      if (mensagens.length === 0) continue;
      recebidas.inc(mensagens.length);

      for (const msg of mensagens) {
        try {
          await processar(msg);
          // Só deleta após processar com sucesso
          await sqs.send(
            new DeleteMessageCommand({
              QueueUrl: QUEUE_URL,
              ReceiptHandle: msg.ReceiptHandle,
            })
          );
        } catch (err) {
          erros.inc();
          logger.error('falha_processamento', {
            message_id: msg.MessageId,
            error: err.message,
            // mensagem não é deletada -> volta para a fila
          });
        }
      }
    } catch (err) {
      logger.error('falha_receive', { error: err.message });
      await new Promise((r) => setTimeout(r, 3_000));
    }
  }

  logger.info('worker_encerrado');
  await redis.quit().catch(() => {});
  server.close();
  process.exit(0);
}

for (const sinal of ['SIGTERM', 'SIGINT']) {
  process.on(sinal, () => {
    logger.info('shutdown_solicitado', { sinal });
    rodando = false;
  });
}

loop();
