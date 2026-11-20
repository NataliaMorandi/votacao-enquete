'use strict';

const { SNSClient, PublishCommand } = require('@aws-sdk/client-sns');
const logger = require('./logger');

const TOPIC_ARN = process.env.SNS_TOPIC_ARN;
const client = new SNSClient({ region: process.env.AWS_REGION });

/**
 * Publica um evento no tópico SNS.
 * As credenciais vêm do IAM Role da instância EC2 (instance profile) —
 * nenhuma access key fica no código ou no .env.
 *
 * Os atributos da mensagem permitem fan-out seletivo por subscription
 * filter policy, caso a arquitetura evolua.
 */
async function publish(tipo, payload, atributos = {}) {
  const messageAttributes = {
    tipo: { DataType: 'String', StringValue: tipo },
  };
  for (const [k, v] of Object.entries(atributos)) {
    messageAttributes[k] = { DataType: 'String', StringValue: String(v) };
  }

  const cmd = new PublishCommand({
    TopicArn: TOPIC_ARN,
    Message: JSON.stringify({ tipo, publicado_em: new Date().toISOString(), ...payload }),
    MessageAttributes: messageAttributes,
  });

  const resp = await client.send(cmd);
  logger.info('sns_publicado', { tipo, message_id: resp.MessageId, ...payload });
  return resp;
}

module.exports = { publish };
