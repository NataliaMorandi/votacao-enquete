'use strict';

/**
 * Logger estruturado em JSON — formato consumido pelo CloudWatch Logs
 * e pelos dashboards (item 4 do enunciado: registros de logs).
 */
function write(level, msg, extra) {
  const line = { ts: new Date().toISOString(), level, msg, service: 'votes-api' };
  if (extra) Object.assign(line, extra);
  // eslint-disable-next-line no-console
  console.log(JSON.stringify(line));
}

module.exports = {
  info: (msg, extra) => write('INFO', msg, extra),
  warn: (msg, extra) => write('WARN', msg, extra),
  error: (msg, extra) => write('ERROR', msg, extra),
};
