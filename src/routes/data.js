const express = require('express');
const crypto = require('crypto');
const { queryAll, run, runInTransaction, queryOne } = require('../dbHelper');
const { getDb } = require('../db');
const { recordAudit } = require('../audit');
const { AppError } = require('../middleware/errorHandler');

const router = express.Router();

const STABLE_EXPORT_VERSION = 1;
const STABLE_SCHEMA_VERSION = '1.0.0';

function sortById(arr) {
  if (!Array.isArray(arr)) return [];
  return [...arr].sort((a, b) => {
    const idA = String(a.id || '');
    const idB = String(b.id || '');
    if (idA < idB) return -1;
    if (idA > idB) return 1;
    return 0;
  });
}

function sortAuditEvents(arr) {
  if (!Array.isArray(arr)) return [];
  return [...arr].sort((a, b) => {
    const tsA = String(a.timestamp || '');
    const tsB = String(b.timestamp || '');
    if (tsA !== tsB) return tsA < tsB ? -1 : 1;
    const etA = String(a.event_type || '');
    const etB = String(b.event_type || '');
    if (etA !== etB) return etA < etB ? -1 : 1;
    const entA = String(a.entity_type || '') + '|' + String(a.entity_id || '');
    const entB = String(b.entity_type || '') + '|' + String(b.entity_id || '');
    return entA < entB ? -1 : 1;
  });
}

function stableStringify(obj) {
  if (obj === null || obj === undefined) return String(obj);
  if (typeof obj !== 'object') return JSON.stringify(obj);
  if (Array.isArray(obj)) {
    return '[' + obj.map(item => stableStringify(item)).join(',') + ']';
  }
  const keys = Object.keys(obj).sort();
  const parts = keys.map(k => JSON.stringify(k) + ':' + stableStringify(obj[k]));
  return '{' + parts.join(',') + '}';
}

function computeContentHash(obj) {
  const str = stableStringify(obj);
  return crypto.createHash('sha256').update(str, 'utf8').digest('hex');
}

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
  const isStable = req.query.stable === 'true' || req.query.stable === '1';

  const instruments = queryAll('SELECT * FROM instruments');
  const configs = queryAll('SELECT * FROM calibration_configs');
  const technicians = queryAll('SELECT * FROM technicians');
  const schedules = queryAll('SELECT * FROM technician_schedules');
  const workOrders = queryAll('SELECT * FROM work_orders');
  const auditEventsRaw = isStable
    ? queryAll('SELECT * FROM audit_events')
    : queryAll('SELECT * FROM audit_events ORDER BY id ASC');

  const parsedAuditEvents = auditEventsRaw.map(e => ({
    ...e,
    old_values: e.old_values ? JSON.parse(e.old_values) : null,
    new_values: e.new_values ? JSON.parse(e.new_values) : null
  }));

  if (isStable) {
    const sortedInstruments = sortById(instruments);
    const sortedConfigs = sortById(configs);
    const sortedTechnicians = sortById(technicians);
    const sortedSchedules = sortById(schedules);
    const sortedWorkOrders = sortById(workOrders);
    const sortedAuditEvents = sortAuditEvents(parsedAuditEvents);

    const entityCounts = {
      instruments: sortedInstruments.length,
      calibration_configs: sortedConfigs.length,
      technicians: sortedTechnicians.length,
      technician_schedules: sortedSchedules.length,
      work_orders: sortedWorkOrders.length,
      audit_events: sortedAuditEvents.length
    };

    const entitiesForHash = {
      instruments: sortedInstruments,
      calibration_configs: sortedConfigs,
      technicians: sortedTechnicians,
      technician_schedules: sortedSchedules,
      work_orders: sortedWorkOrders,
      audit_events: sortedAuditEvents
    };

    const manifestWithoutHash = {
      stable_export_version: STABLE_EXPORT_VERSION,
      schema_version: STABLE_SCHEMA_VERSION,
      export_mode: 'stable',
      entity_counts: entityCounts,
      deterministic_guarantee: 'same-snapshot-same-bytes: 同一数据库快照(不增删改)下，无论调用多少次、是否重启服务，data 字段字节级完全一致',
      ordering_rules: {
        instruments: 'BY id ASC',
        calibration_configs: 'BY id ASC',
        technicians: 'BY id ASC',
        technician_schedules: 'BY id ASC',
        work_orders: 'BY id ASC',
        audit_events: 'BY timestamp ASC, event_type ASC, (entity_type|entity_id) ASC'
      },
      hash_algorithm: 'SHA-256',
      hash_scope: 'manifest(不含content_hash字段) + 全部实体数组(已排序) 的规范化 JSON'
    };

    const hashInput = {
      manifest: manifestWithoutHash,
      ...entitiesForHash
    };
    const contentHash = computeContentHash(hashInput);

    const exportData = {
      manifest: {
        ...manifestWithoutHash,
        content_hash: contentHash
      },
      instruments: sortedInstruments,
      calibration_configs: sortedConfigs,
      technicians: sortedTechnicians,
      technician_schedules: sortedSchedules,
      work_orders: sortedWorkOrders,
      audit_events: sortedAuditEvents
    };

    res.json({ data: exportData });
  } else {
    const exportData = {
      export_version: 1,
      exported_at: new Date().toISOString(),
      export_trace_hint: '导出数据中各实体 ID 与导入时保持一致；audit_events 自增 ID 在导入后重新生成，但可通过 (entity_type, entity_id, event_type, timestamp) 定位对应事件',
      instruments,
      calibration_configs: configs,
      technicians,
      technician_schedules: schedules,
      work_orders: workOrders,
      audit_events: parsedAuditEvents
    };

    recordAudit('EXPORT', 'system', 'full_export', null, { exported_at: exportData.exported_at });
    res.json({ data: exportData });
  }
});

router.post('/import', (req, res) => {
  const data = req.body;
  if (!data || !data.instruments) {
    throw new AppError('Invalid import data: instruments array is required', 400, 'INVALID_IMPORT_DATA');
  }

  const isStablePackage = !!data.manifest;
  const manifestInfo = isStablePackage
    ? {
      stable_export_version: data.manifest.stable_export_version || null,
      schema_version: data.manifest.schema_version || null,
      original_content_hash: data.manifest.content_hash || null,
      entity_counts: data.manifest.entity_counts || null
    }
    : null;

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
    import_mode: isStablePackage ? 'stable_package' : 'legacy_package',
    manifest_info: manifestInfo,
    instruments: { created: 0, skipped: 0, skipped_ids: [], import_audit_emitted: 0 },
    calibration_configs: { created: 0, skipped: 0, skipped_ids: [], import_audit_emitted: 0 },
    technicians: { created: 0, skipped: 0, skipped_ids: [], import_audit_emitted: 0 },
    technician_schedules: { created: 0, skipped: 0, skipped_ids: [] },
    work_orders: { created: 0, skipped: 0, skipped_ids: [], import_audit_emitted: 0 },
    audit_events: {
      created: 0,
      note: '原始 audit_events 重新插入，自增 ID 重新生成；另为每个导入实体追加 ENTITY_IMPORT 审计事件用于追溯'
    },
    entity_import_audits: { created: 0 }
  };

  runInTransaction(() => {
    for (const inst of (data.instruments || [])) {
      const r = run(`INSERT OR IGNORE INTO instruments (id, name, model, serial_number, location, category, status, description, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        [inst.id, inst.name, inst.model || '', inst.serial_number, inst.location || '',
          inst.category || '', inst.status || 'active', inst.description || '',
          inst.created_at || new Date().toISOString(), inst.updated_at || new Date().toISOString()]);
      if (r.changes > 0) {
        result.instruments.created++;
      } else {
        result.instruments.skipped++;
        result.instruments.skipped_ids.push(inst.id);
      }
      insertEntityImportAudit('instrument', inst.id, { serial_number: inst.serial_number });
      result.entity_import_audits.created++;
      result.instruments.import_audit_emitted++;
    }

    for (const cfg of (data.calibration_configs || [])) {
      const r = run(`INSERT OR IGNORE INTO calibration_configs (id, instrument_id, cycle_days, tolerance, standard, version, is_active, effective_from, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        [cfg.id, cfg.instrument_id, cfg.cycle_days, cfg.tolerance || '', cfg.standard || '',
          cfg.version || 1, cfg.is_active !== undefined ? cfg.is_active : 1,
          cfg.effective_from || new Date().toISOString(), cfg.created_at || new Date().toISOString()]);
      if (r.changes > 0) {
        result.calibration_configs.created++;
      } else {
        result.calibration_configs.skipped++;
        result.calibration_configs.skipped_ids.push(cfg.id);
      }
      insertEntityImportAudit('calibration_config', cfg.id, { instrument_id: cfg.instrument_id, version: cfg.version });
      result.entity_import_audits.created++;
      result.calibration_configs.import_audit_emitted++;
    }

    for (const tech of (data.technicians || [])) {
      const r = run(`INSERT OR IGNORE INTO technicians (id, name, employee_id, title, phone, email, status, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        [tech.id, tech.name, tech.employee_id, tech.title || '', tech.phone || '',
          tech.email || '', tech.status || 'active',
          tech.created_at || new Date().toISOString(), tech.updated_at || new Date().toISOString()]);
      if (r.changes > 0) {
        result.technicians.created++;
      } else {
        result.technicians.skipped++;
        result.technicians.skipped_ids.push(tech.id);
      }
      insertEntityImportAudit('technician', tech.id, { employee_id: tech.employee_id });
      result.entity_import_audits.created++;
      result.technicians.import_audit_emitted++;
    }

    for (const sch of (data.technician_schedules || [])) {
      const r = run(`INSERT OR IGNORE INTO technician_schedules (id, technician_id, start_time, end_time, shift_type, notes, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?)`,
        [sch.id, sch.technician_id, sch.start_time, sch.end_time,
          sch.shift_type || 'regular', sch.notes || '', sch.created_at || new Date().toISOString()]);
      if (r.changes > 0) {
        result.technician_schedules.created++;
      } else {
        result.technician_schedules.skipped++;
        result.technician_schedules.skipped_ids.push(sch.id);
      }
    }

    for (const wo of (data.work_orders || [])) {
      const r = run(`INSERT OR IGNORE INTO work_orders (id, instrument_id, config_id, config_version, cycle_days_snapshot, technician_id, status,
           planned_date, scheduled_start, scheduled_end, assigned_date, completed_date, verified_date, result, deviation, certificate_no, notes, created_by, verified_by, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        [wo.id, wo.instrument_id, wo.config_id, wo.config_version || 1, wo.cycle_days_snapshot || 0,
          wo.technician_id || null, wo.status || 'created', wo.planned_date || null,
          wo.scheduled_start || null, wo.scheduled_end || null,
          wo.assigned_date || null, wo.completed_date || null, wo.verified_date || null,
          wo.result || '', wo.deviation || '', wo.certificate_no || '', wo.notes || '',
          wo.created_by || 'system', wo.verified_by || '',
          wo.created_at || new Date().toISOString(), wo.updated_at || new Date().toISOString()]);
      if (r.changes > 0) {
        result.work_orders.created++;
      } else {
        result.work_orders.skipped++;
        result.work_orders.skipped_ids.push(wo.id);
      }
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
        JSON.stringify({
          result,
          traceability_note: '导入实体有 ENTITY_IMPORT 审计事件可追溯；原 audit_events 内容保留但自增ID重新分配；skipped_ids 字段列出因 ID 冲突而跳过的实体'
        }),
        'system', new Date().toISOString()]
    );
  });

  res.json({ data: result });
});

module.exports = router;
