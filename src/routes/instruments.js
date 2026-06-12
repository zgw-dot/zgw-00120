const express = require('express');
const { v4: uuidv4 } = require('uuid');
const { queryAll, queryOne, run } = require('../dbHelper');
const { recordAudit } = require('../audit');
const { AppError } = require('../middleware/errorHandler');

const router = express.Router();

router.get('/', (req, res) => {
  const { status, category } = req.query;
  let sql = 'SELECT * FROM instruments WHERE 1=1';
  const params = [];
  if (status) { sql += ' AND status = ?'; params.push(status); }
  if (category) { sql += ' AND category = ?'; params.push(category); }
  sql += ' ORDER BY created_at DESC';
  const rows = queryAll(sql, params);
  res.json({ data: rows });
});

router.get('/:id', (req, res) => {
  const row = queryOne('SELECT * FROM instruments WHERE id = ?', [req.params.id]);
  if (!row) throw new AppError(`Instrument not found: id=${req.params.id}`, 404, 'NOT_FOUND');
  res.json({ data: row });
});

router.post('/', (req, res) => {
  const { name, model, serial_number, location, category, description } = req.body;
  if (!name || !name.trim()) throw new AppError('name is required', 400, 'VALIDATION_ERROR', { field: 'name' });
  if (!serial_number || !serial_number.trim()) throw new AppError('serial_number is required', 400, 'VALIDATION_ERROR', { field: 'serial_number' });

  const existing = queryOne('SELECT id FROM instruments WHERE serial_number = ?', [serial_number.trim()]);
  if (existing) throw new AppError(`serial_number already exists: ${serial_number}`, 409, 'DUPLICATE_SERIAL', { field: 'serial_number', value: serial_number });

  const id = uuidv4();
  const now = new Date().toISOString();
  run(`INSERT INTO instruments (id, name, model, serial_number, location, category, status, description, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, 'active', ?, ?, ?)`,
    [id, name.trim(), (model || '').trim(), serial_number.trim(), (location || '').trim(), (category || '').trim(), (description || '').trim(), now, now]);

  const row = queryOne('SELECT * FROM instruments WHERE id = ?', [id]);
  recordAudit('CREATE', 'instrument', id, null, row);
  res.status(201).json({ data: row });
});

router.put('/:id', (req, res) => {
  const old = queryOne('SELECT * FROM instruments WHERE id = ?', [req.params.id]);
  if (!old) throw new AppError(`Instrument not found: id=${req.params.id}`, 404, 'NOT_FOUND');

  const { name, model, serial_number, location, category, status, description } = req.body;
  if (serial_number && serial_number.trim() !== old.serial_number) {
    const dup = queryOne('SELECT id FROM instruments WHERE serial_number = ? AND id != ?', [serial_number.trim(), req.params.id]);
    if (dup) throw new AppError(`serial_number already exists: ${serial_number}`, 409, 'DUPLICATE_SERIAL', { field: 'serial_number' });
  }

  const now = new Date().toISOString();
  run(`UPDATE instruments SET name=COALESCE(?,name), model=COALESCE(?,model), serial_number=COALESCE(?,serial_number),
       location=COALESCE(?,location), category=COALESCE(?,category), status=COALESCE(?,status),
       description=COALESCE(?,description), updated_at=? WHERE id=?`,
    [name?.trim(), model?.trim(), serial_number?.trim(), location?.trim(), category?.trim(), status, description?.trim(), now, req.params.id]);

  const row = queryOne('SELECT * FROM instruments WHERE id = ?', [req.params.id]);
  recordAudit('UPDATE', 'instrument', req.params.id, old, row);
  res.json({ data: row });
});

router.delete('/:id', (req, res) => {
  const old = queryOne('SELECT * FROM instruments WHERE id = ?', [req.params.id]);
  if (!old) throw new AppError(`Instrument not found: id=${req.params.id}`, 404, 'NOT_FOUND');

  const openOrders = queryAll("SELECT id FROM work_orders WHERE instrument_id = ? AND status IN ('created','assigned')", [req.params.id]);
  if (openOrders.length > 0) throw new AppError(`Cannot delete instrument: ${openOrders.length} open work orders exist`, 409, 'HAS_OPEN_ORDERS', { orderCount: openOrders.length });

  run('DELETE FROM instruments WHERE id = ?', [req.params.id]);
  recordAudit('DELETE', 'instrument', req.params.id, old, null);
  res.json({ data: { deleted: true, id: req.params.id } });
});

module.exports = router;
