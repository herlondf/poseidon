/**
 * bench-comparison.js — k6 load test for Poseidon benchmark comparison.
 *
 * Tests one endpoint at a time (set via SCENARIO env var).
 * Ramps up VUs gradually to stress the connection/thread model.
 *
 * Env vars:
 *   BASE_URL  = http://host:port
 *   SCENARIO  = ping | json | upload | delay
 *   USERS     = virtual users (default 200)
 *   DURATION  = test duration (default 2m)
 */

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend, Rate, Counter } from 'k6/metrics';

const BASE_URL = __ENV.BASE_URL || 'http://127.0.0.1:9801';
const SCENARIO = __ENV.SCENARIO || 'ping';
const USERS    = parseInt(__ENV.USERS || '200');
const DURATION = __ENV.DURATION || '2m';
const LABEL    = __ENV.LABEL || 'unknown';

const latency  = new Trend('req_latency_ms', true);
const failures = new Rate('req_fail');
const total    = new Counter('req_total');

// 5MB payload for upload test (generated once)
const UPLOAD_PAYLOAD = SCENARIO === 'upload'
  ? 'x'.repeat(5 * 1024 * 1024)
  : '';

export const options = {
  scenarios: {
    load: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '10s', target: Math.floor(USERS / 2) },  // ramp to 50%
        { duration: '10s', target: USERS },                   // ramp to 100%
        { duration: DURATION, target: USERS },                // sustain
        { duration: '5s',  target: 0 },                       // ramp down
      ],
      gracefulStop: '10s',
      gracefulRampDown: '5s',
    },
  },
  thresholds: {
    req_latency_ms: ['p(95)<500', 'p(99)<2000'],
    req_fail:       ['rate<0.05'],
  },
};

export default function () {
  let res;

  switch (SCENARIO) {
    case 'ping':
      res = http.get(BASE_URL + '/ping', { tags: { name: 'ping' }, timeout: '10s' });
      break;
    case 'json':
      res = http.get(BASE_URL + '/json', { tags: { name: 'json' }, timeout: '10s' });
      break;
    case 'upload':
      res = http.post(BASE_URL + '/upload', UPLOAD_PAYLOAD, {
        headers: { 'Content-Type': 'application/octet-stream' },
        tags: { name: 'upload' },
        timeout: '30s',
      });
      break;
    case 'delay':
      res = http.get(BASE_URL + '/delay', { tags: { name: 'delay' }, timeout: '15s' });
      break;
  }

  const ok = res.status >= 200 && res.status < 300;
  latency.add(res.timings.duration);
  total.add(1);
  failures.add(!ok);

  if (!ok) {
    check(res, { ['HTTP ' + res.status]: () => false });
  }
}

export function handleSummary(data) {
  const lat  = (data.metrics.req_latency_ms || {}).values || {};
  const fail = (data.metrics.req_fail || {}).values || {};
  const tot  = (data.metrics.req_total || {}).values || {};
  const reqs = (data.metrics.http_reqs || {}).values || {};
  const dur  = (data.state.testRunDurationMs / 1000).toFixed(1);

  const fms = (v) => v ? (v >= 1000 ? (v/1000).toFixed(2)+'s' : v.toFixed(1)+'ms') : '—';

  const summary = {
    label:    LABEL,
    scenario: SCENARIO,
    users:    USERS,
    duration: dur + 's',
    total:    tot.count || 0,
    rps:      reqs.rate ? +reqs.rate.toFixed(2) : 0,
    latency: {
      avg: +(lat.avg || 0).toFixed(2),
      p50: +(lat.med || 0).toFixed(2),
      p95: +(lat['p(95)'] || 0).toFixed(2),
      p99: +(lat['p(99)'] || 0).toFixed(2),
      max: +(lat.max || 0).toFixed(2),
    },
    errors: +((fail.rate || 0) * 100).toFixed(2),
    errorCount: Math.round((tot.count || 0) * (fail.rate || 0)),
  };

  const text = [
    '',
    `=== ${LABEL} | ${SCENARIO} | ${USERS} VUs | ${dur}s ===`,
    `  Total     : ${(summary.total).toLocaleString()} requests`,
    `  RPS       : ${summary.rps}`,
    `  Lat avg   : ${fms(summary.latency.avg)}`,
    `  Lat p50   : ${fms(summary.latency.p50)}`,
    `  Lat p95   : ${fms(summary.latency.p95)}`,
    `  Lat p99   : ${fms(summary.latency.p99)}`,
    `  Lat max   : ${fms(summary.latency.max)}`,
    `  Errors    : ${summary.errors}% (${summary.errorCount})`,
    '',
  ].join('\n');

  const jsonFile = `/tmp/k6-${LABEL}-${SCENARIO}.json`;

  return {
    [jsonFile]: JSON.stringify(summary, null, 2),
    stdout: text,
  };
}
