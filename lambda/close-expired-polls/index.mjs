/**
 * Lambda close-expired-polls (ESM — compatível com o editor do console, que cria index.mjs)
 * --------------------------------------------------------------------------
 * Disparada pelo EventBridge a cada 1 minuto.
 * Chama o endpoint interno da API, que:
 *   1. fecha as enquetes com prazo vencido;
 *   2. publica o evento `enquete.encerrada` no SNS.
 *
 * Por que via HTTP e não direto no banco?
 *   - A Lambda roda fora da VPC (sem NAT Gateway);
 *   - O Postgres NÃO fica exposto à internet (só a porta 3000 da API);
 *   - A regra de negócio fica em um único lugar (a API).
 *
 * Sem dependências externas: usa o fetch nativo do Node.
 * Handler: index.handler
 */

const API_URL = process.env.API_URL;
const INTERNAL_TOKEN = process.env.INTERNAL_TOKEN;

export const handler = async (event) => {
  const alvo = `${API_URL}/internal/close-expired`;

  try {
    const resp = await fetch(alvo, {
      method: 'POST',
      headers: { 'x-internal-token': INTERNAL_TOKEN },
      signal: AbortSignal.timeout(10_000),
    });

    const texto = await resp.text();

    console.log(
      JSON.stringify({
        ts: new Date().toISOString(),
        level: resp.ok ? 'INFO' : 'WARN',
        msg: 'close_expired_executado',
        service: 'lambda-close-expired',
        status: resp.status,
        resposta: texto.slice(0, 2_000),
        agendado_por: event && event['detail-type'] ? event['detail-type'] : 'manual',
      })
    );

    return { statusCode: resp.status, body: texto };
  } catch (err) {
    // API desligada (EC2 parada) não deve gerar alarme de erro:
    // é um estado esperado do ambiente acadêmico.
    console.log(
      JSON.stringify({
        ts: new Date().toISOString(),
        level: 'WARN',
        msg: 'api_indisponivel',
        service: 'lambda-close-expired',
        alvo,
        error: err.message,
      })
    );
    return { statusCode: 503, body: 'api_indisponivel' };
  }
};
