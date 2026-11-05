import http from 'k6/http';
import { check } from 'k6';
import { Counter } from 'k6/metrics';

// Fixed-prompt, fixed-output-length load test.
// Env:
//   GW_BASE       gateway base URL (default http://localhost:8080)
//   API_KEY       raw API key
//   CONCURRENCY   constant virtual users (default 1)
//   PER_TEST_SEC  scenario duration (default 60s)
//   MAX_TOKENS    requested completion length (default 64)

const GW_BASE = __ENV.GW_BASE || 'http://localhost:8080';
const API_KEY = __ENV.API_KEY || '';
const MAX_TOKENS = Number(__ENV.MAX_TOKENS || 64);
const CONCURRENCY = Number(__ENV.CONCURRENCY || 1);
const PER_TEST_SEC = Number(__ENV.PER_TEST_SEC || 60);

const status200 = new Counter('responses_200');
const status429 = new Counter('responses_429');
const statusOther = new Counter('responses_other');

export const options = {
  discardResponseBodies: true,
  scenarios: {
    fixed: {
      executor: 'constant-vus',
      vus: CONCURRENCY,
      duration: `${PER_TEST_SEC}s`,
    },
  },
};

const PROMPT = 'In exactly three sentences, explain what a Kubernetes node is.';

export default function () {
  const payload = JSON.stringify({
    model: 'qwen2.5-1.5b-instruct',
    messages: [{ role: 'user', content: PROMPT }],
    max_tokens: MAX_TOKENS,
    stream: false,
  });
  const res = http.post(
    `${GW_BASE}/v1/chat/completions`,
    payload,
    {
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${API_KEY}`,
      },
      tags: { model: 'qwen2.5-1.5b-instruct-q4_k_m' },
    },
  );
  if (res.status === 200) status200.add(1);
  else if (res.status === 429) status429.add(1);
  else statusOther.add(1);
  check(res, {
    'status 200': (r) => r.status === 200,
  });
}
