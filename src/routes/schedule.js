const express = require('express');
const { v4: uuidv4 } = require('uuid');
const { queryAll, queryOne, run, runInTransaction } = require('../dbHelper');
const { recordAudit } = require('../audit');
const { AppError } = require('../middleware/errorHandler');
const { buildInstrumentOverdueExplanation } = require('../overdueTrace');

const router = express.Router();

function buildPreplayResponse(params) {
  const { instrument_id, technician_id, scheduled_start, scheduled_end } = params;
  const errors = [];

  if (!instrument_id) errors.push({ code: 'VALIDATION_ERROR', message: 'instrument_id is required', field: 'instrument_id' });
  if (!technician_id) errors.push({ code: 'VALIDATION_ERROR', message: 'technician_id is required', field: 'technician_id' });
  if (!scheduled_start) errors.push({ code: 'VALIDATION_ERROR', message: 'scheduled_start is required', field: 'scheduled_start' });
  if (!scheduled_end) errors.push({ code: 'VALIDATION_ERROR', message: 'scheduled_end is required', field: 'scheduled_end' });

  if (errors.length > 0) {
    return { can_schedule: false, matched_shifts: [], conflict_orders: [], active_config_snapshot: null, next_due_date: null, next_due_date_calc: null, existing_open_order: null, errors };
  }

  const sStart = new Date(scheduled_start);
  const sEnd = new Date(scheduled_end);
  if (isNaN(sStart.getTime()) || isNaN(sEnd.getTime())) {
    errors.push({ code: 'INVALID_DATETIME', message: 'scheduled_start and scheduled_end must be valid ISO datetime strings' });
    return { can_schedule: false, matched_shifts: [], conflict_orders: [], active_config_snapshot: null, next_due_date: null, next_due_date_calc: null, existing_open_order: null, errors };
  }
  if (sStart >= sEnd) {
    errors.push({ code: 'INVALID_TIME_RANGE', message: 'scheduled_start must be before scheduled_end' });
    return { can_schedule: false, matched_shifts: [], conflict_orders: [], active_config_snapshot: null, next_due_date: null, next_due_date_calc: null, existing_open_order: null, errors };
  }

  const inst = queryOne('SELECT * FROM instruments WHERE id = ?', [instrument_id]);
  if (!inst) {
    errors.push({ code: 'NOT_FOUND', message: `Instrument not found: id=${instrument_id}` });
  } else if (inst.status !== 'active') {
    errors.push({ code: 'INSTRUMENT_NOT_ACTIVE', message: `Instrument is not active: status=${inst.status}. Only active instruments can be scheduled for calibration.` });
  }

  const activeConfig = queryOne('SELECT * FROM calibration_configs WHERE instrument_id = ? AND is_active = 1', [instrument_id]);
  if (inst && !activeConfig) {
    errors.push({ code: 'NO_ACTIVE_CONFIG', message: `No active calibration config for instrument: ${instrument_id}. Please create a config first.` });
  }

  const openOrder = queryOne(
    "SELECT * FROM work_orders WHERE instrument_id = ? AND status IN ('created','assigned','completed','returned') ORDER BY created_at DESC LIMIT 1",
    [instrument_id]
  );
  let existingOpenOrder = null;
  if (openOrder) {
    if (openOrder.status !== 'created') {
      errors.push({
        code: 'DUPLICATE_OPEN_ORDER',
        message: `Instrument already has an open work order: id=${openOrder.id}, status=${openOrder.status}. Cannot schedule a new one until it is verified or returned.`,
        details: { existingOrderId: openOrder.id, existingStatus: openOrder.status }
      });
    } else {
      existingOpenOrder = { id: openOrder.id, status: openOrder.status, created_at: openOrder.created_at, cycle_days_snapshot: openOrder.cycle_days_snapshot, config_id: openOrder.config_id, config_version: openOrder.config_version };
    }
  }

  const tech = queryOne('SELECT * FROM technicians WHERE id = ?', [technician_id]);
  if (!tech) {
    errors.push({ code: 'NOT_FOUND', message: `Technician not found: id=${technician_id}` });
  } else if (tech.status !== 'active') {
    errors.push({ code: 'TECHNICIAN_NOT_ACTIVE', message: `Technician is not active: status=${tech.status}. Only active technicians can be assigned.` });
  }

  let matchedShifts = [];
  if (tech) {
    matchedShifts = queryAll(
      `SELECT * FROM technician_schedules WHERE technician_id = ? AND start_time <= ? AND end_time >= ?`,
      [technician_id, scheduled_start, scheduled_end]
    );
    if (matchedShifts.length === 0) {
      errors.push({
        code: 'SCHEDULE_CONFLICT',
        message: `Technician ${tech.name} is not available during ${scheduled_start} to ${scheduled_end}. No matching shift schedule found.`,
        details: { technicianId: technician_id, scheduled_start, scheduled_end, reason: 'No matching shift schedule - technician is not on duty during requested time' }
      });
    }
  }

  let conflictOrders = [];
  if (tech) {
    const excludeId = existingOpenOrder ? existingOpenOrder.id : '';
    conflictOrders = queryAll(
      `SELECT * FROM work_orders WHERE technician_id = ? AND id != ? AND status IN ('assigned','completed') AND scheduled_start < ? AND scheduled_end > ?`,
      [technician_id, excludeId, scheduled_end, scheduled_start]
    );
    if (conflictOrders.length > 0) {
      errors.push({
        code: 'WORK_ORDER_CONFLICT',
        message: `Technician ${tech.name} already has ${conflictOrders.length} work order(s) at the same time.`,
        details: { technicianId: technician_id, conflictOrders: conflictOrders.map(c => ({ id: c.id, status: c.status, scheduled_start: c.scheduled_start, scheduled_end: c.scheduled_end })) }
      });
    }
  }

  let nextDueDate = null;
  let nextDueDateCalc = null;
  if (inst && inst.status === 'active' && activeConfig) {
    try {
      const asOfDate = new Date().toISOString().split('T')[0];
      const explanation = buildInstrumentOverdueExplanation(inst, asOfDate);
      nextDueDate = explanation.base_calculation.next_due_date;
      nextDueDateCalc = {
        cycle_source: explanation.trace.cycle_source,
        applied_cycle_days: explanation.base_calculation.applied_cycle_days,
        last_calibrated_date: explanation.base_calculation.last_calibrated_date,
        is_overdue: explanation.base_calculation.is_overdue,
        days_overdue: explanation.base_calculation.days_overdue
      };
    } catch (_) {}
  }

  return {
    can_schedule: errors.length === 0,
    matched_shifts: matchedShifts.map(s => ({ id: s.id, start_time: s.start_time, end_time: s.end_time, shift_type: s.shift_type })),
    conflict_orders: conflictOrders.map(c => ({ id: c.id, status: c.status, scheduled_start: c.scheduled_start, scheduled_end: c.scheduled_end })),
    active_config_snapshot: activeConfig ? { id: activeConfig.id, version: activeConfig.version, cycle_days: activeConfig.cycle_days, tolerance: activeConfig.tolerance, standard: activeConfig.standard, effective_from: activeConfig.effective_from } : null,
    next_due_date: nextDueDate,
    next_due_date_calc: nextDueDateCalc,
    existing_open_order: existingOpenOrder,
    errors: errors.length > 0 ? errors : undefined
  };
}

router.post('/preplay', (req, res) => {
  const result = buildPreplayResponse(req.body);
  res.json({ data: result });
});

router.post('/confirm', (req, res) => {
  const { instrument_id, technician_id, scheduled_start, scheduled_end, operator, notes, created_by } = req.body;

  if (!instrument_id) throw new AppError('instrument_id is required', 400, 'VALIDATION_ERROR', { field: 'instrument_id' });
  if (!technician_id) throw new AppError('technician_id is required', 400, 'VALIDATION_ERROR', { field: 'technician_id' });
  if (!scheduled_start) throw new AppError('scheduled_start is required', 400, 'VALIDATION_ERROR', { field: 'scheduled_start' });
  if (!scheduled_end) throw new AppError('scheduled_end is required', 400, 'VALIDATION_ERROR', { field: 'scheduled_end' });

  const sStart = new Date(scheduled_start);
  const sEnd = new Date(scheduled_end);
  if (isNaN(sStart.getTime()) || isNaN(sEnd.getTime())) {
    throw new AppError('scheduled_start and scheduled_end must be valid ISO datetime strings', 400, 'INVALID_DATETIME');
  }
  if (sStart >= sEnd) throw new AppError('scheduled_start must be before scheduled_end', 400, 'INVALID_TIME_RANGE');

  const inst = queryOne('SELECT * FROM instruments WHERE id = ?', [instrument_id]);
  if (!inst) throw new AppError(`Instrument not found: id=${instrument_id}`, 404, 'NOT_FOUND');
  if (inst.status !== 'active') throw new AppError(`Instrument is not active: status=${inst.status}`, 400, 'INSTRUMENT_NOT_ACTIVE');

  const activeConfig = queryOne('SELECT * FROM calibration_configs WHERE instrument_id = ? AND is_active = 1', [instrument_id]);
  if (!activeConfig) throw new AppError(`No active calibration config for instrument: ${instrument_id}. Please create a config first.`, 400, 'NO_ACTIVE_CONFIG');

  const openOrder = queryOne(
    "SELECT * FROM work_orders WHERE instrument_id = ? AND status IN ('created','assigned','completed','returned') ORDER BY created_at DESC LIMIT 1",
    [instrument_id]
  );

  let workOrderId;
  let isNewOrder = false;

  if (openOrder) {
    if (openOrder.status !== 'created') {
      throw new AppError(
        `Instrument ${inst.name} (${inst.serial_number}) already has an open work order: id=${openOrder.id}, status=${openOrder.status}. Cannot schedule a new one until it is verified or returned.`,
        409, 'DUPLICATE_OPEN_ORDER',
        { existingOrderId: openOrder.id, existingStatus: openOrder.status }
      );
    }
    workOrderId = openOrder.id;
  }

  const tech = queryOne('SELECT * FROM technicians WHERE id = ?', [technician_id]);
  if (!tech) throw new AppError(`Technician not found: id=${technician_id}`, 404, 'NOT_FOUND');
  if (tech.status !== 'active') throw new AppError(`Technician is not active: status=${tech.status}`, 400, 'TECHNICIAN_NOT_ACTIVE');

  const scheduleMatches = queryAll(
    `SELECT * FROM technician_schedules WHERE technician_id = ? AND start_time <= ? AND end_time >= ?`,
    [technician_id, scheduled_start, scheduled_end]
  );
  if (scheduleMatches.length === 0) {
    throw new AppError(
      `Technician ${tech.name} is not available during ${scheduled_start} to ${scheduled_end}. No matching shift schedule found.`,
      409, 'SCHEDULE_CONFLICT',
      { technicianId: technician_id, scheduled_start, scheduled_end, reason: 'No matching shift schedule - technician is not on duty during requested time' }
    );
  }

  const excludeId = workOrderId || '';
  const orderConflicts = queryAll(
    `SELECT * FROM work_orders WHERE technician_id = ? AND id != ? AND status IN ('assigned','completed') AND scheduled_start < ? AND scheduled_end > ?`,
    [technician_id, excludeId, scheduled_end, scheduled_start]
  );
  if (orderConflicts.length > 0) {
    throw new AppError(
      `Technician ${tech.name} already has ${orderConflicts.length} work order(s) at the same time.`,
      409, 'WORK_ORDER_CONFLICT',
      { technicianId: technician_id, conflictOrders: orderConflicts.map(c => ({ id: c.id, status: c.status })) }
    );
  }

  const op = operator || 'system';
  const now = new Date().toISOString();
  const configSnapshot = {
    config_id: activeConfig.id,
    config_version: activeConfig.version,
    cycle_days: activeConfig.cycle_days,
    tolerance: activeConfig.tolerance,
    standard: activeConfig.standard,
    effective_from: activeConfig.effective_from
  };

  let resultOrder;

  runInTransaction(() => {
    if (!workOrderId) {
      workOrderId = uuidv4();
      run(`INSERT INTO work_orders (id, instrument_id, config_id, config_version, cycle_days_snapshot, status, planned_date, notes, created_by, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, 'created', ?, ?, ?, ?, ?)`,
        [workOrderId, instrument_id, activeConfig.id, activeConfig.version, activeConfig.cycle_days,
          scheduled_start.split('T')[0], notes || '', created_by || op, now, now]);
      isNewOrder = true;
    }

    run('UPDATE work_orders SET technician_id=?, status=?, assigned_date=?, scheduled_start=?, scheduled_end=?, updated_at=? WHERE id=?',
      [technician_id, 'assigned', now, scheduled_start, scheduled_end, now, workOrderId]);

    resultOrder = queryOne('SELECT * FROM work_orders WHERE id = ?', [workOrderId]);
  });

  if (isNewOrder) {
    recordAudit('CREATE', 'work_order', workOrderId, null, {
      instrument_id, config_id: activeConfig.id, config_version: activeConfig.version,
      cycle_days_snapshot: activeConfig.cycle_days, created_by: created_by || op,
      source: 'schedule_confirm'
    }, op);
  }

  recordAudit('SCHEDULE_CONFIRM', 'work_order', workOrderId,
    { status: 'created', technician_id: null },
    { status: 'assigned', technician_id, scheduled_start, scheduled_end, config_snapshot: configSnapshot, confirmed_by: op },
    op
  );

  res.status(201).json({
    data: resultOrder,
    meta: {
      config_snapshot: configSnapshot,
      confirmed_by: op,
      confirmed_at: now,
      is_new_order: isNewOrder
    }
  });
});

module.exports = router;
