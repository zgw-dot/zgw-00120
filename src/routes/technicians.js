const express = require('express');
const { v4: uuidv4 } = require('uuid');
const { queryAll, queryOne, run } = require('../dbHelper');
const { recordAudit } = require('../audit');
const { AppError } = require('../middleware/errorHandler');

const router = express.Router();

router.get('/', (req, res) => {
  const { status } = req.query;
  let sql = 'SELECT * FROM technicians WHERE 1=1';
  const params = [];
  if (status) { sql += ' AND status = ?'; params.push(status); }
  sql += ' ORDER BY created_at DESC';
  const rows = queryAll(sql, params);
  res.json({ data: rows });
});

router.get('/:id', (req, res) => {
  const row = queryOne('SELECT * FROM technicians WHERE id = ?', [req.params.id]);
  if (!row) throw new AppError(`Technician not found: id=${req.params.id}`, 404, 'NOT_FOUND');
  res.json({ data: row });
});

router.post('/', (req, res) => {
  const { name, employee_id, title, phone, email } = req.body;
  if (!name || !name.trim()) throw new AppError('name is required', 400, 'VALIDATION_ERROR', { field: 'name' });
  if (!employee_id || !employee_id.trim()) throw new AppError('employee_id is required', 400, 'VALIDATION_ERROR', { field: 'employee_id' });

  const existing = queryOne('SELECT id FROM technicians WHERE employee_id = ?', [employee_id.trim()]);
  if (existing) throw new AppError(`employee_id already exists: ${employee_id}`, 409, 'DUPLICATE_EMPLOYEE_ID', { field: 'employee_id' });

  const id = uuidv4();
  const now = new Date().toISOString();
  run(`INSERT INTO technicians (id, name, employee_id, title, phone, email, status, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, 'active', ?, ?)`,
    [id, name.trim(), employee_id.trim(), title || '', phone || '', email || '', now, now]);

  const row = queryOne('SELECT * FROM technicians WHERE id = ?', [id]);
  recordAudit('CREATE', 'technician', id, null, row);
  res.status(201).json({ data: row });
});

router.put('/:id', (req, res) => {
  const old = queryOne('SELECT * FROM technicians WHERE id = ?', [req.params.id]);
  if (!old) throw new AppError(`Technician not found: id=${req.params.id}`, 404, 'NOT_FOUND');

  const { name, employee_id, title, phone, email, status } = req.body;
  if (employee_id && employee_id.trim() !== old.employee_id) {
    const dup = queryOne('SELECT id FROM technicians WHERE employee_id = ? AND id != ?', [employee_id.trim(), req.params.id]);
    if (dup) throw new AppError(`employee_id already exists: ${employee_id}`, 409, 'DUPLICATE_EMPLOYEE_ID');
  }

  const now = new Date().toISOString();
  run(`UPDATE technicians SET name=COALESCE(?,name), employee_id=COALESCE(?,employee_id),
       title=COALESCE(?,title), phone=COALESCE(?,phone), email=COALESCE(?,email),
       status=COALESCE(?,status), updated_at=? WHERE id=?`,
    [name?.trim(), employee_id?.trim(), title, phone, email, status, now, req.params.id]);

  const row = queryOne('SELECT * FROM technicians WHERE id = ?', [req.params.id]);
  recordAudit('UPDATE', 'technician', req.params.id, old, row);
  res.json({ data: row });
});

router.delete('/:id', (req, res) => {
  const old = queryOne('SELECT * FROM technicians WHERE id = ?', [req.params.id]);
  if (!old) throw new AppError(`Technician not found: id=${req.params.id}`, 404, 'NOT_FOUND');

  const assignedOrders = queryAll("SELECT id FROM work_orders WHERE technician_id = ? AND status IN ('created','assigned')", [req.params.id]);
  if (assignedOrders.length > 0) throw new AppError(`Cannot delete technician: ${assignedOrders.length} assigned work orders exist`, 409, 'HAS_ASSIGNED_ORDERS');

  run('DELETE FROM technician_schedules WHERE technician_id = ?', [req.params.id]);
  run('DELETE FROM technicians WHERE id = ?', [req.params.id]);
  recordAudit('DELETE', 'technician', req.params.id, old, null);
  res.json({ data: { deleted: true, id: req.params.id } });
});

router.get('/:id/schedules', (req, res) => {
  const { start_date, end_date } = req.query;
  let sql = 'SELECT * FROM technician_schedules WHERE technician_id = ?';
  const params = [req.params.id];
  if (start_date) { sql += ' AND end_time >= ?'; params.push(start_date); }
  if (end_date) { sql += ' AND start_time <= ?'; params.push(end_date); }
  sql += ' ORDER BY start_time';
  const rows = queryAll(sql, params);
  res.json({ data: rows });
});

router.post('/:id/schedules', (req, res) => {
  const tech = queryOne('SELECT * FROM technicians WHERE id = ?', [req.params.id]);
  if (!tech) throw new AppError(`Technician not found: id=${req.params.id}`, 404, 'NOT_FOUND');

  const { start_time, end_time, shift_type, notes } = req.body;
  if (!start_time) throw new AppError('start_time is required', 400, 'VALIDATION_ERROR', { field: 'start_time' });
  if (!end_time) throw new AppError('end_time is required', 400, 'VALIDATION_ERROR', { field: 'end_time' });

  const start = new Date(start_time);
  const end = new Date(end_time);
  if (isNaN(start.getTime()) || isNaN(end.getTime())) {
    throw new AppError('start_time and end_time must be valid ISO datetime strings', 400, 'INVALID_DATETIME');
  }
  if (start >= end) throw new AppError('start_time must be before end_time', 400, 'INVALID_TIME_RANGE', { start_time, end_time });

  const conflicts = queryAll(
    `SELECT * FROM technician_schedules 
     WHERE technician_id = ? AND start_time < ? AND end_time > ?`,
    [req.params.id, end_time, start_time]
  );
  if (conflicts.length > 0) {
    throw new AppError(
      `Technician ${tech.name} has schedule conflict: ${conflicts.length} overlapping shift(s) found.`,
      409, 'SCHEDULE_CONFLICT',
      { conflicts: conflicts.map(c => ({ id: c.id, start_time: c.start_time, end_time: c.end_time })) }
    );
  }

  const id = uuidv4();
  const now = new Date().toISOString();
  run(`INSERT INTO technician_schedules (id, technician_id, start_time, end_time, shift_type, notes, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
    [id, req.params.id, start_time, end_time, shift_type || 'regular', notes || '', now]);

  const row = queryOne('SELECT * FROM technician_schedules WHERE id = ?', [id]);
  recordAudit('CREATE', 'technician_schedule', id, null, row);
  res.status(201).json({ data: row });
});

router.delete('/:techId/schedules/:scheduleId', (req, res) => {
  const old = queryOne('SELECT * FROM technician_schedules WHERE id = ? AND technician_id = ?', [req.params.scheduleId, req.params.techId]);
  if (!old) throw new AppError('Schedule entry not found', 404, 'NOT_FOUND');
  run('DELETE FROM technician_schedules WHERE id = ?', [req.params.scheduleId]);
  recordAudit('DELETE', 'technician_schedule', req.params.scheduleId, old, null);
  res.json({ data: { deleted: true, id: req.params.scheduleId } });
});

module.exports = router;
