'use strict';

const express = require('express');
const { Pool } = require('pg');
const redis = require('redis');
const winston = require('winston');

// ── Logger ─────────────────────────────────────────────────────────────────
const logger = winston.createLogger({
  level: process.env.LOG_LEVEL || 'info',
  format: winston.format.combine(
    winston.format.timestamp(),
    winston.format.errors({ stack: true }),
    winston.format.json()
  ),
  transports: [new winston.transports.Console()],
});

// ── Database clients ────────────────────────────────────────────────────────
const pgPool = new Pool({
  host: process.env.DB_HOST || 'postgres',
  port: parseInt(process.env.DB_PORT || '5432'),
  database: process.env.DB_NAME || 'appdb',
  user: process.env.DB_USER || 'appuser',
  password: process.env.DB_PASSWORD || 'changeme',
  max: 10,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 2000,
});

let redisClient;

async function connectRedis() {
  redisClient = redis.createClient({
    url: `redis://${process.env.REDIS_HOST || 'redis'}:${process.env.REDIS_PORT || 6379}`,
  });
  redisClient.on('error', (err) => logger.error('Redis error', { err: err.message }));
  await redisClient.connect();
  logger.info('Redis connected');
}

// ── App ──────────────────────────────────────────────────────────────────────
const app = express();
app.use(express.json());

// Request logging middleware
app.use((req, _res, next) => {
  logger.info('Incoming request', {
    method: req.method,
    path: req.path,
    ip: req.ip,
  });
  next();
});

// ── Routes ───────────────────────────────────────────────────────────────────

/**
 * GET /health
 * Lightweight liveness probe – always returns 200 if the process is alive.
 */
app.get('/health', (_req, res) => {
  res.status(200).json({ status: 'ok', timestamp: new Date().toISOString() });
});

/**
 * GET /status
 * Readiness probe – checks connectivity to Postgres and Redis.
 */
app.get('/status', async (_req, res) => {
  const checks = { postgres: 'unknown', redis: 'unknown' };

  try {
    const client = await pgPool.connect();
    await client.query('SELECT 1');
    client.release();
    checks.postgres = 'healthy';
  } catch (err) {
    logger.warn('Postgres health check failed', { err: err.message });
    checks.postgres = 'unhealthy';
  }

  try {
    await redisClient.ping();
    checks.redis = 'healthy';
  } catch (err) {
    logger.warn('Redis health check failed', { err: err.message });
    checks.redis = 'unhealthy';
  }

  const allHealthy = Object.values(checks).every((v) => v === 'healthy');
  res.status(allHealthy ? 200 : 503).json({
    status: allHealthy ? 'ready' : 'degraded',
    checks,
    version: process.env.APP_VERSION || '1.0.0',
    uptime: process.uptime(),
  });
});

/**
 * POST /process
 * Accepts a JSON payload, persists it to Postgres, caches it in Redis,
 * and returns the saved record.
 */
app.post('/process', async (req, res) => {
  const { data } = req.body;

  if (!data) {
    return res.status(400).json({ error: 'Missing required field: data' });
  }

  try {
    // Persist to Postgres
    const result = await pgPool.query(
      'INSERT INTO jobs (payload, created_at) VALUES ($1, NOW()) RETURNING id, payload, created_at',
      [JSON.stringify(data)]
    );
    const record = result.rows[0];

    // Cache in Redis (TTL 300 s)
    await redisClient.setEx(`job:${record.id}`, 300, JSON.stringify(record));

    logger.info('Job processed', { jobId: record.id });
    return res.status(201).json({ success: true, job: record });
  } catch (err) {
    logger.error('Error processing job', { err: err.message });
    return res.status(500).json({ error: 'Internal server error' });
  }
});

// 404 handler
app.use((_req, res) => res.status(404).json({ error: 'Not found' }));

// Global error handler
app.use((err, _req, res, _next) => {
  logger.error('Unhandled error', { err: err.message, stack: err.stack });
  res.status(500).json({ error: 'Internal server error' });
});

// ── Bootstrap ─────────────────────────────────────────────────────────────
async function bootstrap() {
  try {
    await connectRedis();

    // Ensure the jobs table exists
    await pgPool.query(`
      CREATE TABLE IF NOT EXISTS jobs (
        id         SERIAL PRIMARY KEY,
        payload    JSONB        NOT NULL,
        created_at TIMESTAMPTZ  NOT NULL DEFAULT NOW()
      )
    `);
    logger.info('Database schema ready');

    const PORT = parseInt(process.env.PORT || '3000');
    const server = app.listen(PORT, '0.0.0.0', () => {
      logger.info(`Server listening on port ${PORT}`);
    });

    // Graceful shutdown
    const shutdown = async (signal) => {
      logger.info(`${signal} received, shutting down gracefully…`);
      server.close(async () => {
        await pgPool.end();
        await redisClient.quit();
        logger.info('Connections closed. Goodbye.');
        process.exit(0);
      });
    };

    process.on('SIGTERM', () => shutdown('SIGTERM'));
    process.on('SIGINT', () => shutdown('SIGINT'));
  } catch (err) {
    logger.error('Failed to start application', { err: err.message });
    process.exit(1);
  }
}

bootstrap();

module.exports = app; // exported for testing
