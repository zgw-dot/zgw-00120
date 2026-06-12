const express = require('express');
const { v4: uuidv4 } = require('uuid');
const { queryAll, queryOne, run } = require('../dbHelper');
const { recordAudit } = require('../audit');
const { AppError } = require('../middleware/errorHandler');

const router = express.Router();

router.get('/', (req, res) => {
  const { instrument_id, is_active } = req.query;
  let sql = 'SELECT * FROM calibration_configs WHERE 1=1';
  const params = [];
  if (instrument_id) { sql += ' AND instrument_id = ?'; params.push(instrument_id); }
  if (is_active !== undefined) { sql += ' AND is_active = ?'; params.push(is_active === 'true' || is_active === '1' ? 1 : 0); }
  sql += ' ORDER BY instrument_id, version DESC';
  const rows = queryAll(sql, params);
  res.json({ data: rows });
});

router.get('/:id', (req, res) => {
  const row = queryOne('SELECT * FROM calibration_configs WHERE id = ?', [req.params.id]);
  if (!row) throw new AppError(`Calibration config not found: id=${req.params.id}`, 404, 'NOT_FOUND');
  res.json({ data: row });
});

router.post('/', (req, res) => {
  const { instrument_id, cycle_days, tolerance, standard } = req.body;

  if (!instrument_id) throw new AppError('instrument_id is required', 400, 'VALIDATION_ERROR', { field: 'instrument_id' });
  const inst = queryOne('SELECT id FROM instruments WHERE id = ?', [instrument_id]);
  if (!inst) throw new AppError(`Instrument not found: id=${instrument_id}`, 404, 'NOT_FOUND');

  if (cycle_days === undefined || cycle_days === null) throw new AppError('cycle_days is required', 400, 'VALIDATION_ERROR', { field: 'cycle_days' });
  if (!Number.isInteger(cycle_days) || cycle_days <= 0) throw new AppError('cycle_days must be a positive integer', 400, 'INVALID_CYCLE_DAYS', { field: 'cycle_days', value: cycle_days });

  const now = new Date().toISOString();
  const currentActive = queryOne('SELECT * FROM calibration_configs WHERE instrument_id = ? AND is_active = 1', [instrument_id]);

  let version = 1;
  if (currentActive) {
    run('UPDATE calibration_configs SET is_active = 0 WHERE id = ?', [currentActive.id]);
    version = currentActive.version + 1;
  }

  const id = uuidv4();
  run(`INSERT INTO calibration_configs (id, instrument_id, cycle_days, tolerance, standard, version, is_active, effective_from, created_at)
       VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)`,
    [id, instrument_id, cycle_days, tolerance || '', standard || '', version, now, now]);

  const row = queryOne('SELECT * FROM calibration_configs WHERE id = ?', [id]);
  recordAudit('CREATE', 'calibration_config', id, null, row);
  res.status(201).json({ data: row });
});

router.put('/:id', (req, res) => {
  const old = queryOne('SELECT * FROM calibration_configs WHERE id = ?', [req.params.id]);
  if (!old) throw new AppError(`Calibration config not found: id=${req.params.id}`, 404, 'NOT_FOUND');

  const { cycle_days, tolerance, standard } = req.body;
  if (cycle_days !== undefined && (!Number.isInteger(cycle_days) || cycle_days <= 0)) {
    throw new AppError('cycle_days must be a positive integer', 400, 'INVALID_CYCLE_DAYS', { field: 'cycle_days', value: cycle_days });
  }

  run(`UPDATE calibration_configs SET cycle_days=COALESCE(?,cycle_days), tolerance=COALESCE(?,tolerance),
       standard=COALESCE(?,standard) WHERE id=?`,
    [cycle_days, tolerance, standard, req.params.id]);

  const row = queryOne('SELECT * FROM calibration_configs WHERE id = ?', [req.params.id]);
  recordAudit('UPDATE', 'calibration_config', req.params.id, old, row);
  res.json({ data: row });
});

router.get('/instrument/:instrumentId/history', (req, res) => {
  const rows = queryAll('SELECT * FROM calibration_configs WHERE instrument_id = ? ORDER BY version ASC', [req.params.instrumentId]);
  res.json({ data: rows });
});

module.exports = router;
