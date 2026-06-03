import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate } from 'k6/metrics';

export const fallbackProbeObserved = new Rate('fallback_probe_observed');

export const options = {
  scenarios: {
    chat_non_stream: {
      executor: 'constant-vus',
      vus: Number(__ENV.CHAT_VUS || 50),
      duration: __ENV.CHAT_DURATION || '2m',
      exec: 'chatNonStream',
    },
    retry_429_probe: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.FALLBACK_PROBE_RATE || 1),
      timeUnit: '30s',
      duration: __ENV.FALLBACK_PROBE_DURATION || '2m',
      preAllocatedVUs: 1,
      maxVUs: 4,
      exec: 'retry429Probe',
    },
    fallback_5xx_probe: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.FALLBACK_PROBE_RATE || 1),
      timeUnit: '30s',
      duration: __ENV.FALLBACK_PROBE_DURATION || '2m',
      preAllocatedVUs: 1,
      maxVUs: 4,
      exec: 'fallback5xxProbe',
    },
    fallback_timeout_probe: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.FALLBACK_PROBE_RATE || 1),
      timeUnit: '30s',
      duration: __ENV.FALLBACK_PROBE_DURATION || '2m',
      preAllocatedVUs: 1,
      maxVUs: 4,
      exec: 'fallbackTimeoutProbe',
    },
    fallback_eof_probe: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.FALLBACK_PROBE_RATE || 1),
      timeUnit: '30s',
      duration: __ENV.FALLBACK_PROBE_DURATION || '2m',
      preAllocatedVUs: 1,
      maxVUs: 4,
      exec: 'fallbackEofProbe',
    },
  },
  thresholds: {
    'http_req_failed{scenario:chat_non_stream}': ['rate<0.01'],
    http_req_duration: ['p(95)<2000'],
    fallback_probe_observed: ['rate>0.95'],
  },
};

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';
const API_KEY = __ENV.API_KEY || 'test-key';
const MODEL = __ENV.MODEL || 'gpt-4-test';
const SCENARIO_SELECTOR = (__ENV.SCENARIO_SELECTOR || 'body').toLowerCase();
const SCENARIO_HEADER = __ENV.SCENARIO_HEADER || 'X-Mock-Scenario';
const ENDPOINT_SCENARIO_PREFIX = (__ENV.MOCK_ENDPOINT_PREFIX || '/__scenario').replace(/\/$/, '');
const REQUEST_TIMEOUT = __ENV.REQUEST_TIMEOUT || '10s';
const SLEEP_SECONDS = Number(__ENV.SLEEP_SECONDS || 1);

function chatPath(mockScenario) {
  if (mockScenario && SCENARIO_SELECTOR === 'endpoint') {
    return `${ENDPOINT_SCENARIO_PREFIX}/${encodeURIComponent(mockScenario)}/v1/chat/completions`;
  }

  const path = '/v1/chat/completions';
  if (mockScenario && SCENARIO_SELECTOR === 'query') {
    return `${path}?scenario=${encodeURIComponent(mockScenario)}`;
  }

  return path;
}

function chatPayload(mockScenario) {
  const payload = {
    model: MODEL,
    messages: [{ role: 'user', content: 'hello' }],
    stream: false,
  };

  if (mockScenario && SCENARIO_SELECTOR === 'body') {
    payload.mock_scenario = mockScenario;
  }

  return JSON.stringify(payload);
}

function chatHeaders(mockScenario) {
  const headers = {
    Authorization: `Bearer ${API_KEY}`,
    'Content-Type': 'application/json',
    'x-ai-trace-id': `k6-${__VU}-${__ITER}`,
  };

  if (mockScenario && SCENARIO_SELECTOR === 'header') {
    headers[SCENARIO_HEADER] = mockScenario;
  }

  return headers;
}

function postChat(label, mockScenario = null) {
  const res = http.post(`${BASE_URL}${chatPath(mockScenario)}`, chatPayload(mockScenario), {
    headers: chatHeaders(mockScenario),
    timeout: REQUEST_TIMEOUT,
    tags: {
      probe: label,
      mock_scenario: mockScenario || '200',
    },
  });

  if (!mockScenario) {
    check(res, {
      'status is 200': (r) => r.status === 200,
      'has request id': (r) => !!r.headers['X-Request-Id'],
    });
    sleep(SLEEP_SECONDS);
    return;
  }

  const observed = check(res, {
    [`${label}: fallback succeeded or retryable failure surfaced`]: (r) =>
      r.status === 200 || r.status === 429 || r.status === 502 || r.status === 504 || !!r.error_code,
    [`${label}: response is bounded`]: (r) => !!r.error_code || (r.timings && r.timings.duration < 10000),
  });
  fallbackProbeObserved.add(observed);
  sleep(SLEEP_SECONDS);
}

export function chatNonStream() {
  postChat('chat_non_stream');
}

export function retry429Probe() {
  postChat('retry_429_probe', '429');
}

export function fallback5xxProbe() {
  postChat('fallback_5xx_probe', '5xx');
}

export function fallbackTimeoutProbe() {
  postChat('fallback_timeout_probe', 'timeout');
}

export function fallbackEofProbe() {
  postChat('fallback_eof_probe', 'eof');
}

export default function () {
  chatNonStream();
}
