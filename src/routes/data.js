const express = require('express');
const { queryAll, run, runInTransaction } = require('../dbHelper');
const { getDb } = require('../db');
const { recordAudit } = require('../audit');
const { AppError } = require('../middleware/errorHandler');

const router = express.Router();

function insertEntityImportAudit(entityType, entityId, extra = {}) {
  const db = getDb();
  try {
    db.run(
      `INSERT INTO audit_events (event_type, entity_type, entity_id, old_values, new_values, operator, timestamp)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
      ['ENTITY_IMPORT', entityType, entityId, null,
        JSON.stringify({ import_source: 'full_data_import', ...extra }),
        'import_job', new Date().toISOString()]
    );
  } catch (_) {
  }
}

router.get('/export', (req, res) => {
  const instruments = queryAll('SELECT * FROM instruments');
  const configs = queryAll('SELECT * FROM calibration_configs');
  const technicians = queryAll('SELECT * FROM technicians');
  const schedules = queryAll('SELECT * FROM technician_schedules');
  const workOrders = queryAll('SELECT * FROM work_orders');
  const auditEvents = queryAll('SELECT * FROM audit_events ORDER BY id ASC');

  const exportData = {
    export_version: 1,
    exported_at: new Date().toISOString(),
    export_trace_hint: '导出数据中各实体 ID 与导入时保持一致；audit_events 自增 ID 在导入后重新生成，但可通过 (entity_type, entity_id, event_type, timestamp) 定位对应事件',
    instruments,
    calibration_configs: configs,
    technicians,
    technician_schedules: schedules,
    work_orders: workOrders,
    audit_events: auditEvents.map(e => ({
      ...e,
      old_values: e.old_values ? JSON.parse(e.old_values) : null,
      new_values: e.new_values ? JSON.parse(e.new_values) : null
    }))
  };

  recordAudit('EXPORT', 'system', 'full_export', null, { exported_at: exportData.exported_at });
  res.json({ data: exportData });
});

router.post('/import', (req, res) => {
  const data = req.body;
  if (!data || !data.instruments) {
    throw new AppError('Invalid import data: instruments array is required', 400, 'INVALID_IMPORT_DATA');
  }

  const validationErrors = [];

  if (data.calibration_configs) {
    for (const cfg of data.calibration_configs) {
      if (cfg.cycle_days !== undefined && (!Number.isInteger(cfg.cycle_days) || cfg.cycle_days <= 0)) {
        validationErrors.push({
          type: 'INVALID_CYCLE_DAYS',
          entity: 'calibration_config',
          id: cfg.id,
          message: `calibration_config id=${cfg.id} has invalid cycle_days=${cfg.cycle_days} (must be positive integer)`
        });
      }
    }
  }

  if (validationErrors.length > 0) {
    throw new AppError(`Import validation failed: ${validationErrors.length} error(s) found`, 400, 'IMPORT_VALIDATION_FAILED', { errors: validationErrors });
  }

  const result = {
    instruments: { created: 0, skipped: 0, import_audit_emitted: 0 },
    calibration_configs: { created: 0, skipped: 0, import_audit_emitted: 0 },
    technicians: { created: 0, skipped: 0, import_audit_emitted: 0 },
    technician_schedules: { created: 0, skipped: 0 },
    work_orders: { created: 0, skipped: 0, import_audit_emitted: 0 },
    audit_events: { created: 0, note: '原始 audit_events 重新插入，自增 ID 重新生成；另为每个导入实体追加 ENTITY_IMPORT 审计事件用于追溯' },
    entity_import_audits: { created: 0 }
  };

  runInTransaction(() => {
    for (const inst of (data.instruments || [])) {
      try {
        run(`INSERT OR IGNORE INTO instruments (id, name, model, serial_number, location, category, status, description, created_at, updated_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          [inst.id, inst.name, inst.model || '', inst.serial_number, inst.location || '',
            inst.category || '', inst.status || 'active', inst.description || '',
            inst.created_at || new Date().toISOString(), inst.updated_at || new Date().toISOString()]);
        result.instruments.created++;
      } catch { result.instruments.skipped++; }
      insertEntityImportAudit('instrument', inst.id, { serial_number: inst.serial_number });
      result.entity_import_audits.created++;
      result.instruments.import_audit_emitted++;
    }

    for (const cfg of (data.calibration_configs || [])) {
      try {
        run(`INSERT OR IGNORE INTO calibration_configs (id, instrument_id, cycle_days, tolerance, standard, version, is_active, effective_from, created_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          [cfg.id, cfg.instrument_id, cfg.cycle_days, cfg.tolerance || '', cfg.standard || '',
            cfg.version || 1, cfg.is_active !== undefined ? cfg.is_active : 1,
            cfg.effective_from || new Date().toISOString(), cfg.created_at || new Date().toISOString()]);
        result.calibration_configs.created++;
      } catch { result.calibration_configs.skipped++; }
      insertEntityImportAudit('calibration_config', cfg.id, { instrument_id: cfg.instrument_id, version: cfg.version });
      result.entity_import_audits.created++;
      result.calibration_configs.import_audit_emitted++;
    }

    for (const tech of (data.technicians || [])) {
      try {
        run(`INSERT OR IGNORE INTO technicians (id, name, employee_id, title, phone, email, status, created_at, updated_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          [tech.id, tech.name, tech.employee_id, tech.title || '', tech.phone || '',
            tech.email || '', tech.status || 'active',
            tech.created_at || new Date().toISOString(), tech.updated_at || new Date().toISOString()]);
        result.technicians.created++;
      } catch { result.technicians.skipped++; }
      insertEntityImportAudit('technician', tech.id, { employee_id: tech.employee_id });
      result.entity_import_audits.created++;
      result.technicians.import_audit_emitted++;
    }

    for (const sch of (data.technician_schedules || [])) {
      try {
        run(`INSERT OR IGNORE INTO technician_schedules (id, technician_id, start_time, end_time, shift_type, notes, created_at)
             VALUES (?, ?, ?, ?, ?, ?, ?)`,
          [sch.id, sch.technician_id, sch.start_time, sch.end_time,
            sch.shift_type || 'regular', sch.notes || '', sch.created_at || new Date().toISOString()]);
        result.technician_schedules.created++;
      } catch { result.technician_schedules.skipped++; }
    }

    for (const wo of (data.work_orders || [])) {
      try {
        run(`INSERT OR IGNORE INTO work_orders (id, instrument_id, config_id, config_version, cycle_days_snapshot, technician_id, status,
             planned_date, scheduled_start, scheduled_end, assigned_date, completed_date, verified_date, result, deviation, certificate_no, notes, created_by, verified_by, created_at, updated_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          [wo.id, wo.instrument_id, wo.config_id, wo.config_version || 1, wo.cycle_days_snapshot || 0,
            wo.technician_id || null, wo.status || 'created', wo.planned_date || null,
            wo.scheduled_start || null, wo.scheduled_end || null,
            wo.assigned_date || null, wo.completed_date || null, wo.verified_date || null,
            wo.result || '', wo.deviation || '', wo.certificate_no || '', wo.notes || '',
            wo.created_by || 'system', wo.verified_by || '',
            wo.created_at || new Date().toISOString(), wo.updated_at || new Date().toISOString()]);
        result.work_orders.created++;
      } catch { result.work_orders.skipped++; }
      insertEntityImportAudit('work_order', wo.id, { instrument_id: wo.instrument_id, status: wo.status, config_id: wo.config_id });
      result.entity_import_audits.created++;
      result.work_orders.import_audit_emitted++;
    }

    for (const ae of (data.audit_events || [])) {
      run(`INSERT INTO audit_events (event_type, entity_type, entity_id, old_values, new_values, operator, timestamp)
           VALUES (?, ?, ?, ?, ?, ?, ?)`,
        [ae.event_type, ae.entity_type, ae.entity_id,
          ae.old_values ? (typeof ae.old_values === 'string' ? ae.old_values : JSON.stringify(ae.old_values)) : null,
          ae.new_values ? (typeof ae.new_values === 'string' ? ae.new_values : JSON.stringify(ae.new_values)) : null,
          ae.operator || 'system', ae.timestamp || new Date().toISOString()]);
      result.audit_events.created++;
    }

    const db = getDb();
    db.run(
      `INSERT INTO audit_events (event_type, entity_type, entity_id, old_values, new_values, operator, timestamp)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
      ['IMPORT', 'system', 'full_import', null,
        JSON.stringify({ result, traceability_note: '导入实体有 ENTITY_IMPORT 审计事件可追溯；原 audit_events 内容保留但自增ID重新分配' }),
        'system', new Date().toISOString()]
    );
  });

  res.json({ data: result });
});

module.exports = router;
