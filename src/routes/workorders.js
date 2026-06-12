const express = require('express');
const { v4: uuidv4 } = require('uuid');
const { queryAll, queryOne, run, runInTransaction } = require('../dbHelper');
const { recordAudit } = require('../audit');
const { AppError } = require('../middleware/errorHandler');

const router = express.Router();

router.get('/', (req, res) => {
  const { status, instrument_id, technician_id } = req.query;
  let sql = 'SELECT * FROM work_orders WHERE 1=1';
  const params = [];
  if (status) { sql += ' AND status = ?'; params.push(status); }
  if (instrument_id) { sql += ' AND instrument_id = ?'; params.push(instrument_id); }
  if (technician_id) { sql += ' AND technician_id = ?'; params.push(technician_id); }
  sql += ' ORDER BY created_at DESC';
  const rows = queryAll(sql, params);
  res.json({ data: rows });
});

router.get('/:id', (req, res) => {
  const row = queryOne('SELECT * FROM work_orders WHERE id = ?', [req.params.id]);
  if (!row) throw new AppError(`Work order not found: id=${req.params.id}`, 404, 'NOT_FOUND');
  res.json({ data: row });
});

router.post('/', (req, res) => {
  const { instrument_id, planned_date, created_by, notes } = req.body;

  if (!instrument_id) throw new AppError('instrument_id is required', 400, 'VALIDATION_ERROR', { field: 'instrument_id' });

  const inst = queryOne('SELECT * FROM instruments WHERE id = ?', [instrument_id]);
  if (!inst) throw new AppError(`Instrument not found: id=${instrument_id}`, 404, 'NOT_FOUND');
  if (inst.status !== 'active') throw new AppError(`Instrument is not active: status=${inst.status}`, 400, 'INSTRUMENT_NOT_ACTIVE');

  const openOrder = queryOne(
    "SELECT id, status FROM work_orders WHERE instrument_id = ? AND status IN ('created','assigned','completed','returned') ORDER BY created_at DESC LIMIT 1",
    [instrument_id]
  );
  if (openOrder) {
    throw new AppError(
      `Instrument ${inst.name} (${inst.serial_number}) already has an open work order: id=${openOrder.id}, status=${openOrder.status}. Cannot create a new one until it is verified or returned.`,
      409, 'DUPLICATE_OPEN_ORDER',
      { existingOrderId: openOrder.id, existingStatus: openOrder.status }
    );
  }

  const activeConfig = queryOne('SELECT * FROM calibration_configs WHERE instrument_id = ? AND is_active = 1', [instrument_id]);
  if (!activeConfig) throw new AppError(`No active calibration config for instrument: ${instrument_id}. Please create a config first.`, 400, 'NO_ACTIVE_CONFIG');

  const id = uuidv4();
  const now = new Date().toISOString();
  run(`INSERT INTO work_orders (id, instrument_id, config_id, config_version, cycle_days_snapshot, status, planned_date, notes, created_by, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, 'created', ?, ?, ?, ?, ?)`,
    [id, instrument_id, activeConfig.id, activeConfig.version, activeConfig.cycle_days,
      planned_date || null, notes || '', created_by || 'system', now, now]);

  const row = queryOne('SELECT * FROM work_orders WHERE id = ?', [id]);
  recordAudit('CREATE', 'work_order', id, null, row);
  res.status(201).json({ data: row });
});

router.post('/:id/assign', (req, res) => {
  const order = queryOne('SELECT * FROM work_orders WHERE id = ?', [req.params.id]);
  if (!order) throw new AppError(`Work order not found: id=${req.params.id}`, 404, 'NOT_FOUND');
  if (order.status !== 'created') throw new AppError(`Cannot assign: current status is '${order.status}', expected 'created'`, 400, 'INVALID_STATUS_TRANSITION', { currentStatus: order.status, expectedStatus: 'created' });

  const { technician_id, scheduled_start, scheduled_end } = req.body;
  if (!technician_id) throw new AppError('technician_id is required', 400, 'VALIDATION_ERROR', { field: 'technician_id' });
  if (!scheduled_start) throw new AppError('scheduled_start is required', 400, 'VALIDATION_ERROR', { field: 'scheduled_start' });
  if (!scheduled_end) throw new AppError('scheduled_end is required', 400, 'VALIDATION_ERROR', { field: 'scheduled_end' });

  const sStart = new Date(scheduled_start);
  const sEnd = new Date(scheduled_end);
  if (isNaN(sStart.getTime()) || isNaN(sEnd.getTime())) {
    throw new AppError('scheduled_start and scheduled_end must be valid ISO datetime strings', 400, 'INVALID_DATETIME');
  }
  if (sStart >= sEnd) throw new AppError('scheduled_start must be before scheduled_end', 400, 'INVALID_TIME_RANGE');

  const tech = queryOne('SELECT * FROM technicians WHERE id = ?', [technician_id]);
  if (!tech) throw new AppError(`Technician not found: id=${technician_id}`, 404, 'NOT_FOUND');
  if (tech.status !== 'active') throw new AppError(`Technician is not active: status=${tech.status}`, 400, 'TECHNICIAN_NOT_ACTIVE');

  const scheduleMatches = queryAll(
    `SELECT * FROM technician_schedules 
     WHERE technician_id = ? AND start_time <= ? AND end_time >= ?`,
    [technician_id, scheduled_start, scheduled_end]
  );
  if (scheduleMatches.length === 0) {
    throw new AppError(
      `Technician ${tech.name} is not available during ${scheduled_start} to ${scheduled_end}. No matching shift schedule found.`,
      409, 'SCHEDULE_CONFLICT',
      {
        technicianId: technician_id,
        scheduled_start,
        scheduled_end,
        reason: 'No matching shift schedule - technician is not on duty during requested time'
      }
    );
  }

  const orderConflicts = queryAll(
    `SELECT * FROM work_orders 
     WHERE technician_id = ? AND id != ? AND status IN ('assigned','completed')
       AND scheduled_start < ? AND scheduled_end > ?`,
    [technician_id, order.id, scheduled_end, scheduled_start]
  );
  if (orderConflicts.length > 0) {
    throw new AppError(
      `Technician ${tech.name} already has ${orderConflicts.length} work order(s) at the same time.`,
      409, 'WORK_ORDER_CONFLICT',
      {
        technicianId: technician_id,
        scheduled_start,
        scheduled_end,
        conflictOrders: orderConflicts.map(c => ({ id: c.id, status: c.status }))
      }
    );
  }

  const now = new Date().toISOString();
  run('UPDATE work_orders SET technician_id=?, status=?, assigned_date=?, scheduled_start=?, scheduled_end=?, updated_at=? WHERE id=?',
    [technician_id, 'assigned', now, scheduled_start, scheduled_end, now, order.id]);

  const row = queryOne('SELECT * FROM work_orders WHERE id = ?', [order.id]);
  recordAudit('STATUS_CHANGE', 'work_order', order.id, { status: order.status, technician_id: order.technician_id }, { status: 'assigned', technician_id }, req.body.operator);
  res.json({ data: row });
});

router.post('/:id/complete', (req, res) => {
  const order = queryOne('SELECT * FROM work_orders WHERE id = ?', [req.params.id]);
  if (!order) throw new AppError(`Work order not found: id=${req.params.id}`, 404, 'NOT_FOUND');

  if (order.status === 'created') {
    throw new AppError('Cannot complete: work order must be assigned to a technician first. Current status is "created" (unassigned).', 400, 'NOT_ASSIGNED', { currentStatus: order.status, technicianId: order.technician_id });
  }
  if (order.status !== 'assigned' && order.status !== 'returned') {
    throw new AppError(`Cannot complete: current status is '${order.status}', expected 'assigned' or 'returned'`, 400, 'INVALID_STATUS_TRANSITION', { currentStatus: order.status });
  }

  const { result, deviation, certificate_no, notes } = req.body;
  if (!result || !result.trim()) throw new AppError('result is required when completing a work order', 400, 'VALIDATION_ERROR', { field: 'result' });

  const now = new Date().toISOString();
  run(`UPDATE work_orders SET status='completed', completed_date=?, result=?, deviation=?, certificate_no=?,
       notes=COALESCE(?,notes), updated_at=? WHERE id=?`,
    [now, result.trim(), deviation || '', certificate_no || '', notes, now, order.id]);

  const row = queryOne('SELECT * FROM work_orders WHERE id = ?', [order.id]);
  recordAudit('STATUS_CHANGE', 'work_order', order.id, { status: order.status }, { status: 'completed' }, req.body.operator);
  res.json({ data: row });
});

router.post('/:id/verify', (req, res) => {
  const order = queryOne('SELECT * FROM work_orders WHERE id = ?', [req.params.id]);
  if (!order) throw new AppError(`Work order not found: id=${req.params.id}`, 404, 'NOT_FOUND');
  if (order.status !== 'completed') throw new AppError(`Cannot verify: current status is '${order.status}', expected 'completed'`, 400, 'INVALID_STATUS_TRANSITION', { currentStatus: order.status, expectedStatus: 'completed' });

  const { verified_by } = req.body;
  const now = new Date().toISOString();
  run("UPDATE work_orders SET status='verified', verified_date=?, verified_by=?, updated_at=? WHERE id=?",
    [now, verified_by || 'system', now, order.id]);

  const row = queryOne('SELECT * FROM work_orders WHERE id = ?', [order.id]);
  recordAudit('STATUS_CHANGE', 'work_order', order.id, { status: order.status }, { status: 'verified', verified_by }, req.body.operator);
  res.json({ data: row });
});

router.post('/:id/return', (req, res) => {
  const order = queryOne('SELECT * FROM work_orders WHERE id = ?', [req.params.id]);
  if (!order) throw new AppError(`Work order not found: id=${req.params.id}`, 404, 'NOT_FOUND');
  if (order.status !== 'completed') throw new AppError(`Cannot return: current status is '${order.status}', expected 'completed'`, 400, 'INVALID_STATUS_TRANSITION', { currentStatus: order.status, expectedStatus: 'completed' });

  const { notes } = req.body;
  const now = new Date().toISOString();
  run(`UPDATE work_orders SET status='returned', result='', deviation='', certificate_no='',
       notes=COALESCE(?,notes), updated_at=? WHERE id=?`,
    [notes || 'Returned for rework', now, order.id]);

  const row = queryOne('SELECT * FROM work_orders WHERE id = ?', [order.id]);
  recordAudit('STATUS_CHANGE', 'work_order', order.id, { status: order.status }, { status: 'returned' }, req.body.operator);
  res.json({ data: row });
});

router.post('/:id/reassign', (req, res) => {
  const order = queryOne('SELECT * FROM work_orders WHERE id = ?', [req.params.id]);
  if (!order) throw new AppError(`Work order not found: id=${req.params.id}`, 404, 'NOT_FOUND');
  if (order.status !== 'returned') throw new AppError(`Cannot reassign: current status is '${order.status}', expected 'returned'`, 400, 'INVALID_STATUS_TRANSITION', { currentStatus: order.status, expectedStatus: 'returned' });

  const { technician_id, scheduled_start, scheduled_end } = req.body;
  if (!technician_id) throw new AppError('technician_id is required for reassignment', 400, 'VALIDATION_ERROR', { field: 'technician_id' });

  const tech = queryOne('SELECT * FROM technicians WHERE id = ?', [technician_id]);
  if (!tech) throw new AppError(`Technician not found: id=${technician_id}`, 404, 'NOT_FOUND');
  if (tech.status !== 'active') throw new AppError(`Technician is not active`, 400, 'TECHNICIAN_NOT_ACTIVE');

  let sStart = scheduled_start || order.scheduled_start;
  let sEnd = scheduled_end || order.scheduled_end;
  if (sStart && sEnd) {
    const scheduleMatches = queryAll(
      `SELECT * FROM technician_schedules 
       WHERE technician_id = ? AND start_time <= ? AND end_time >= ?`,
      [technician_id, sStart, sEnd]
    );
    if (scheduleMatches.length === 0) {
      throw new AppError(
        `Technician ${tech.name} is not available during requested time.`,
        409, 'SCHEDULE_CONFLICT',
        { reason: 'No matching shift schedule' }
      );
    }

    const orderConflicts = queryAll(
      `SELECT * FROM work_orders 
       WHERE technician_id = ? AND id != ? AND status IN ('assigned','completed')
         AND scheduled_start < ? AND scheduled_end > ?`,
      [technician_id, order.id, sEnd, sStart]
    );
    if (orderConflicts.length > 0) {
      throw new AppError(
        `Technician ${tech.name} already has work order(s) at the same time.`,
        409, 'WORK_ORDER_CONFLICT',
        { conflictOrders: orderConflicts.map(c => ({ id: c.id, status: c.status })) }
      );
    }
  }

  const now = new Date().toISOString();
  run('UPDATE work_orders SET technician_id=?, status=?, assigned_date=?, scheduled_start=COALESCE(?,scheduled_start), scheduled_end=COALESCE(?,scheduled_end), updated_at=? WHERE id=?',
    [technician_id, 'assigned', now, sStart, sEnd, now, order.id]);

  const row = queryOne('SELECT * FROM work_orders WHERE id = ?', [order.id]);
  recordAudit('STATUS_CHANGE', 'work_order', order.id, { status: order.status, technician_id: order.technician_id }, { status: 'assigned', technician_id }, req.body.operator);
  res.json({ data: row });
});

module.exports = router;
