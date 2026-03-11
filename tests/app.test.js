'use strict';

/**
 * Unit / integration tests for the Node.js API.
 *
 * Postgres and Redis calls are mocked so the suite runs without
 * live infrastructure (pure CI-friendly).
 */

const request = require('supertest');

// ── Mock pg ───────────────────────────────────────────────────────────────
const mockQuery = jest.fn();
const mockRelease = jest.fn();
const mockConnect = jest.fn().mockResolvedValue({ query: mockQuery, release: mockRelease });

jest.mock('pg', () => ({
  Pool: jest.fn().mockImplementation(() => ({
    connect: mockConnect,
    query: mockQuery,
    end: jest.fn().mockResolvedValue(undefined),
  })),
}));

// ── Mock redis ────────────────────────────────────────────────────────────
const mockPing = jest.fn().mockResolvedValue('PONG');
const mockSetEx = jest.fn().mockResolvedValue('OK');
const mockRedisConnect = jest.fn().mockResolvedValue(undefined);
const mockQuit = jest.fn().mockResolvedValue(undefined);

jest.mock('redis', () => ({
  createClient: jest.fn().mockImplementation(() => ({
    connect: mockRedisConnect,
    ping: mockPing,
    setEx: mockSetEx,
    quit: mockQuit,
    on: jest.fn(),
  })),
}));

// ── Load app after mocks are in place ────────────────────────────────────
let app;

beforeAll(async () => {
  // Bootstrap creates the jobs table – mock that query
  mockQuery.mockResolvedValue({ rows: [] });
  // Require inside beforeAll so mocks are registered first
  app = require('../src/app');
  // Small delay to let async bootstrap settle
  await new Promise((r) => setTimeout(r, 100));
});

afterEach(() => jest.clearAllMocks());

// ── Tests ─────────────────────────────────────────────────────────────────

describe('GET /health', () => {
  it('returns 200 with status ok', async () => {
    const res = await request(app).get('/health');
    expect(res.statusCode).toBe(200);
    expect(res.body.status).toBe('ok');
    expect(res.body.timestamp).toBeDefined();
  });
});

describe('GET /status', () => {
  it('returns 200 when all dependencies are healthy', async () => {
    mockQuery.mockResolvedValueOnce({ rows: [{ '?column?': 1 }] }); // pg SELECT 1
    mockPing.mockResolvedValueOnce('PONG');

    const res = await request(app).get('/status');
    expect(res.statusCode).toBe(200);
    expect(res.body.status).toBe('ready');
    expect(res.body.checks.postgres).toBe('healthy');
    expect(res.body.checks.redis).toBe('healthy');
  });

  it('returns 503 when postgres is unreachable', async () => {
    mockConnect.mockRejectedValueOnce(new Error('Connection refused'));
    mockPing.mockResolvedValueOnce('PONG');

    const res = await request(app).get('/status');
    expect(res.statusCode).toBe(503);
    expect(res.body.status).toBe('degraded');
    expect(res.body.checks.postgres).toBe('unhealthy');
  });

  it('returns 503 when redis is unreachable', async () => {
    mockQuery.mockResolvedValueOnce({ rows: [] });
    mockPing.mockRejectedValueOnce(new Error('Redis connection refused'));

    const res = await request(app).get('/status');
    expect(res.statusCode).toBe(503);
    expect(res.body.checks.redis).toBe('unhealthy');
  });
});

describe('POST /process', () => {
  it('returns 201 with job record on valid payload', async () => {
    const fakeRecord = {
      id: 42,
      payload: JSON.stringify({ foo: 'bar' }),
      created_at: new Date().toISOString(),
    };
    mockQuery.mockResolvedValueOnce({ rows: [fakeRecord] });
    mockSetEx.mockResolvedValueOnce('OK');

    const res = await request(app)
      .post('/process')
      .send({ data: { foo: 'bar' } })
      .set('Content-Type', 'application/json');

    expect(res.statusCode).toBe(201);
    expect(res.body.success).toBe(true);
    expect(res.body.job.id).toBe(42);
  });

  it('returns 400 when data field is missing', async () => {
    const res = await request(app)
      .post('/process')
      .send({})
      .set('Content-Type', 'application/json');

    expect(res.statusCode).toBe(400);
    expect(res.body.error).toMatch(/Missing required field/);
  });

  it('returns 500 on database error', async () => {
    mockQuery.mockRejectedValueOnce(new Error('DB write failed'));

    const res = await request(app)
      .post('/process')
      .send({ data: { key: 'value' } })
      .set('Content-Type', 'application/json');

    expect(res.statusCode).toBe(500);
    expect(res.body.error).toBe('Internal server error');
  });
});

describe('Unknown route', () => {
  it('returns 404 for unregistered paths', async () => {
    const res = await request(app).get('/unknown-route');
    expect(res.statusCode).toBe(404);
  });
});
