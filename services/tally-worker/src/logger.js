'use strict';

/**
 * Logger estruturado em JSON — consumido pelo CloudWatch Logs.
 */
function write(level, msg, extra) {
  const line = { ts: new Date().toISOString(), level, msg, service: 'tally-worker' };
  if (extra) Object.assign(line, extra);
  // eslint-disable-next-line no-console
  console.log(JSON.stringify(line));
}

module.exports = {
  info: (msg, extra) => write('INFO', msg, extra),
  warn: (msg, extra) => write('WARN', msg, extra),
  error: (msg, extra) => write('ERROR', msg, extra),
};
