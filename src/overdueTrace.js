const { queryAll, queryOne } = require('./dbHelper');

function findAuditEventId(entityType, entityId, eventType, beforeTimestamp = null) {
  let sql = 'SELECT id FROM audit_events WHERE entity_type = ? AND entity_id = ? AND event_type = ?';
  const params = [entityType, entityId, eventType];
  if (beforeTimestamp) {
    sql += ' AND timestamp <= ?';
    params.push(beforeTimestamp);
  }
  sql += ' ORDER BY id DESC LIMIT 1';
  const row = queryOne(sql, params);
  return row ? row.id : null;
}

function findEntityImportAuditId(entityType, entityId) {
  return findAuditEventId(entityType, entityId, 'ENTITY_IMPORT');
}

function hasSystemImportEventNear(entityCreatedAt) {
  if (!entityCreatedAt) return false;
  const row = queryOne(
    "SELECT id FROM audit_events WHERE entity_type = 'system' AND event_type = 'IMPORT' AND ABS(strftime('%s', timestamp) - strftime('%s', ?)) < 5 LIMIT 1",
    [entityCreatedAt]
  );
  return row ? row.id : null;
}

function isEntityImported(entityType, entityId, entityCreatedAt) {
  const direct = findEntityImportAuditId(entityType, entityId);
  if (direct) return { is_imported: true, evidence: 'ENTITY_IMPORT_AUDIT', audit_id: direct };
  const indirect = hasSystemImportEventNear(entityCreatedAt);
  if (indirect) return { is_imported: true, evidence: 'SYSTEM_IMPORT_PROXIMITY', audit_id: indirect };
  return { is_imported: false, evidence: 'SYSTEM_CREATED', audit_id: null };
}

function buildOpenOrderInfo(instrumentId) {
  const openOrder = queryOne(
    "SELECT * FROM work_orders WHERE instrument_id = ? AND status IN ('created','assigned','completed','returned') ORDER BY created_at DESC LIMIT 1",
    [instrumentId]
  );
  if (!openOrder) return null;
  return {
    id: openOrder.id,
    status: openOrder.status,
    created_at: openOrder.created_at,
    technician_id: openOrder.technician_id || null,
    scheduled_start: openOrder.scheduled_start || null,
    scheduled_end: openOrder.scheduled_end || null,
    warning: '此工单为未完成状态，未参与 next_due_date 计算，仅作参考展示'
  };
}

function computeNextDueFromVerifiedOrder(lastVerified, asOfDate) {
  const verifiedDate = lastVerified.verified_date
    ? lastVerified.verified_date.split('T')[0]
    : (lastVerified.completed_date ? lastVerified.completed_date.split('T')[0] : null);
  if (!verifiedDate) return { nextDueDate: null, lastCalibratedDate: null };

  const cycleDays = lastVerified.cycle_days_snapshot;
  const d = new Date(verifiedDate);
  d.setDate(d.getDate() + cycleDays);
  const nextDueDate = d.toISOString().split('T')[0];
  return { nextDueDate, lastCalibratedDate: verifiedDate, cycleDays };
}

function computeNextDueFromActiveConfig(instrument, activeConfig) {
  const createdDate = instrument.created_at.split('T')[0];
  const cycleDays = activeConfig.cycle_days;
  const d = new Date(createdDate);
  d.setDate(d.getDate() + cycleDays);
  const nextDueDate = d.toISOString().split('T')[0];
  return { nextDueDate, lastCalibratedDate: null, cycleDays, anchorDate: createdDate };
}

function buildVerifiedOrderTrace(lastVerified, instrument, asOfDate) {
  const { nextDueDate, lastCalibratedDate, cycleDays } = computeNextDueFromVerifiedOrder(lastVerified, asOfDate);

  const snapshotConfig = queryOne('SELECT * FROM calibration_configs WHERE id = ?', [lastVerified.config_id]);
  const activeConfig = queryOne('SELECT * FROM calibration_configs WHERE instrument_id = ? AND is_active = 1', [instrument.id]);

  const verifyAuditId = findAuditEventId('work_order', lastVerified.id, 'STATUS_CHANGE', lastVerified.verified_date || lastVerified.updated_at);
  const woCreateAuditId = findAuditEventId('work_order', lastVerified.id, 'CREATE');
  const cfgCreateAuditId = snapshotConfig ? findAuditEventId('calibration_config', snapshotConfig.id, 'CREATE') : null;

  const importInfo = isEntityImported('work_order', lastVerified.id, lastVerified.created_at);

  const returnedCount = queryOne(
    "SELECT COUNT(*) as cnt FROM audit_events WHERE entity_type = 'work_order' AND entity_id = ? AND event_type = 'STATUS_CHANGE' AND new_values LIKE '%returned%'",
    [lastVerified.id]
  )?.cnt || 0;

  let due = null;
  let daysOverdue = 0;
  let isOverdue = false;
  if (nextDueDate && asOfDate > nextDueDate) {
    due = new Date(nextDueDate);
    const asOf = new Date(asOfDate);
    daysOverdue = Math.floor((asOf - due) / (1000 * 60 * 60 * 24));
    isOverdue = true;
  }

  return {
    base_calculation: {
      next_due_date: nextDueDate,
      last_calibrated_date: lastCalibratedDate,
      applied_cycle_days: cycleDays,
      as_of: asOfDate,
      is_overdue: isOverdue,
      days_overdue: daysOverdue
    },
    trace: {
      cycle_source: 'work_order_snapshot',
      cycle_source_readable: '最近一次已复核工单的 cycle_days 快照',
      work_order: {
        id: lastVerified.id,
        status: lastVerified.status,
        verified_date: lastVerified.verified_date,
        completed_date: lastVerified.completed_date,
        created_at: lastVerified.created_at,
        created_by: lastVerified.created_by,
        verified_by: lastVerified.verified_by,
        technician_id: lastVerified.technician_id,
        result: lastVerified.result,
        certificate_no: lastVerified.certificate_no,
        cycle_days_snapshot: lastVerified.cycle_days_snapshot,
        config_id_snapshot: lastVerified.config_id,
        config_version_snapshot: lastVerified.config_version,
        returned_count_before_verify: returnedCount
      },
      snapshot_config: snapshotConfig ? {
        id: snapshotConfig.id,
        version: snapshotConfig.version,
        cycle_days: snapshotConfig.cycle_days,
        tolerance: snapshotConfig.tolerance,
        standard: snapshotConfig.standard,
        effective_from: snapshotConfig.effective_from,
        is_active_now: snapshotConfig.is_active === 1,
        note: snapshotConfig.is_active === 1
          ? '该配置当前仍为活跃配置，与快照一致'
          : '该配置已被新版本替代，仅用于追溯历史计算依据'
      } : null,
      active_config_now: activeConfig ? {
        id: activeConfig.id,
        version: activeConfig.version,
        cycle_days: activeConfig.cycle_days,
        version_diff_note: activeConfig.id === lastVerified.config_id
          ? '当前活跃配置与工单快照配置相同'
          : `当前活跃配置版本已更新为 v${activeConfig.version}(cycle=${activeConfig.cycle_days}天)，但历史计算仍按工单快照执行`
      } : null,
      reason: {
        code: 'USING_LAST_VERIFIED_WORK_ORDER',
        message: `基于最近一次复核通过的工单（${lastVerified.id}）按快照周期 ${cycleDays} 天计算：${lastCalibratedDate} + ${cycleDays}天 = ${nextDueDate}`,
        fallback_used: false
      },
      audit_event_ids: {
        work_order_create: woCreateAuditId,
        work_order_verify: verifyAuditId,
        snapshot_config_create: cfgCreateAuditId,
        related_all: (() => {
          const all = queryAll(
            "SELECT id, event_type, operator, timestamp FROM audit_events WHERE entity_id IN (?, ?, ?) ORDER BY id ASC",
            [lastVerified.id, lastVerified.config_id, instrument.id]
          ).map(r => r.id);
          return all;
        })()
      },
      import_info: {
        is_imported: importInfo.is_imported,
        evidence: importInfo.evidence,
        related_audit_id: importInfo.audit_id,
        data_integrity: `工单 ID(${lastVerified.id})、配置 ID(${lastVerified.config_id}) 均为导入时保留的原始 ID，追溯链接保持完整`
      }
    }
  };
}

function buildActiveConfigTrace(instrument, activeConfig, asOfDate, missingReasonDetail) {
  const { nextDueDate, cycleDays, anchorDate } = computeNextDueFromActiveConfig(instrument, activeConfig);

  const cfgCreateAuditId = findAuditEventId('calibration_config', activeConfig.id, 'CREATE');
  const instCreateAuditId = findAuditEventId('instrument', instrument.id, 'CREATE');
  const importInfo = isEntityImported('instrument', instrument.id, instrument.created_at);

  let due = null;
  let daysOverdue = 0;
  let isOverdue = false;
  if (nextDueDate && asOfDate > nextDueDate) {
    due = new Date(nextDueDate);
    const asOf = new Date(asOfDate);
    daysOverdue = Math.floor((asOf - due) / (1000 * 60 * 60 * 24));
    isOverdue = true;
  }

  const reasonMessages = {
    NO_VERIFIED_ORDER: `未查询到已复核通过的校准工单，按当前活跃配置(v${activeConfig.version}, ${cycleDays}天)计算：入库日期 ${anchorDate} + ${cycleDays}天 = ${nextDueDate}`,
    ONLY_OPEN_ORDERS: `存在未完成工单(状态为 created/assigned/completed/returned)，但无已复核记录，按活跃配置兜底：${anchorDate} + ${cycleDays}天 = ${nextDueDate}`,
    NO_WORK_ORDERS_AT_ALL: `从未创建过任何校准工单，按活跃配置兜底：入库日期 ${anchorDate} + ${cycleDays}天 = ${nextDueDate}`
  };

  return {
    base_calculation: {
      next_due_date: nextDueDate,
      last_calibrated_date: null,
      applied_cycle_days: cycleDays,
      as_of: asOfDate,
      is_overdue: isOverdue,
      days_overdue: daysOverdue
    },
    trace: {
      cycle_source: 'active_config_fallback',
      cycle_source_readable: '当前活跃配置（兜底，因为查不到已复核工单）',
      work_order: null,
      snapshot_config: null,
      active_config_now: {
        id: activeConfig.id,
        version: activeConfig.version,
        cycle_days: activeConfig.cycle_days,
        tolerance: activeConfig.tolerance,
        standard: activeConfig.standard,
        effective_from: activeConfig.effective_from,
        anchor_date_used: anchorDate,
        anchor_source: 'instrument.created_at（入库/导入时间）'
      },
      reason: {
        code: missingReasonDetail.code,
        message: reasonMessages[missingReasonDetail.code] || reasonMessages.NO_VERIFIED_ORDER,
        fallback_used: true,
        debug_info: missingReasonDetail.debug || null
      },
      audit_event_ids: {
        work_order_create: null,
        work_order_verify: null,
        snapshot_config_create: null,
        active_config_create: cfgCreateAuditId,
        instrument_create: instCreateAuditId
      },
      import_info: {
        is_imported: importInfo.is_imported,
        evidence: importInfo.evidence,
        related_audit_id: importInfo.audit_id,
        data_integrity: `配置 ID(${activeConfig.id})、仪器 ID(${instrument.id}) 保持原样`
      }
    }
  };
}

function buildNoActiveConfigTrace(instrument, asOfDate) {
  const importInfo = isEntityImported('instrument', instrument.id, instrument.created_at);
  return {
    base_calculation: {
      next_due_date: null,
      last_calibrated_date: null,
      applied_cycle_days: null,
      as_of: asOfDate,
      is_overdue: false,
      days_overdue: 0
    },
    trace: {
      cycle_source: 'unavailable',
      cycle_source_readable: '无法计算（无活跃校准配置）',
      work_order: null,
      snapshot_config: null,
      active_config_now: null,
      reason: {
        code: 'NO_ACTIVE_CONFIG',
        message: '该仪器没有活跃的校准配置，请先创建配置后再查询逾期',
        fallback_used: false
      },
      audit_event_ids: {},
      import_info: {
        is_imported: importInfo.is_imported,
        evidence: importInfo.evidence,
        related_audit_id: importInfo.audit_id
      }
    }
  };
}

function buildInstrumentOverdueExplanation(instrument, asOfDate) {
  const activeConfig = queryOne('SELECT * FROM calibration_configs WHERE instrument_id = ? AND is_active = 1', [instrument.id]);
  if (!activeConfig) {
    return {
      instrument_id: instrument.id,
      instrument_name: instrument.name,
      serial_number: instrument.serial_number,
      category: instrument.category,
      location: instrument.location,
      ...buildNoActiveConfigTrace(instrument, asOfDate),
      open_work_order: buildOpenOrderInfo(instrument.id)
    };
  }

  const lastVerified = queryOne(
    "SELECT * FROM work_orders WHERE instrument_id = ? AND status = 'verified' ORDER BY verified_date DESC LIMIT 1",
    [instrument.id]
  );

  const allOrders = queryAll('SELECT id, status FROM work_orders WHERE instrument_id = ?', [instrument.id]);
  const hasAnyOrder = allOrders.length > 0;
  const hasOnlyOpen = hasAnyOrder && allOrders.every(o => ['created', 'assigned', 'completed', 'returned'].includes(o.status));

  if (lastVerified) {
    return {
      instrument_id: instrument.id,
      instrument_name: instrument.name,
      serial_number: instrument.serial_number,
      category: instrument.category,
      location: instrument.location,
      ...buildVerifiedOrderTrace(lastVerified, instrument, asOfDate),
      open_work_order: buildOpenOrderInfo(instrument.id)
    };
  }

  let reasonCode = 'NO_VERIFIED_ORDER';
  let debug = `total_orders=${allOrders.length}, statuses=${allOrders.map(o => o.status).join(',')}`;
  if (!hasAnyOrder) reasonCode = 'NO_WORK_ORDERS_AT_ALL';
  else if (hasOnlyOpen) reasonCode = 'ONLY_OPEN_ORDERS';

  return {
    instrument_id: instrument.id,
    instrument_name: instrument.name,
    serial_number: instrument.serial_number,
    category: instrument.category,
    location: instrument.location,
    ...buildActiveConfigTrace(instrument, activeConfig, asOfDate, { code: reasonCode, debug }),
    open_work_order: buildOpenOrderInfo(instrument.id)
  };
}

function getAllOverdueExplanations(asOfDate) {
  const instruments = queryAll("SELECT * FROM instruments WHERE status = 'active'");
  const results = instruments.map(inst => buildInstrumentOverdueExplanation(inst, asOfDate));
  results.sort((a, b) => b.base_calculation.days_overdue - a.base_calculation.days_overdue);
  return results;
}

function getOverdueListCompact(asOfDate) {
  const explanations = getAllOverdueExplanations(asOfDate);
  return explanations.map(e => ({
    instrument_id: e.instrument_id,
    instrument_name: e.instrument_name,
    serial_number: e.serial_number,
    category: e.category,
    location: e.location,
    applied_cycle_days: e.base_calculation.applied_cycle_days,
    cycle_source: e.trace.cycle_source,
    snapshot_config_id: e.trace.work_order ? e.trace.work_order.config_id_snapshot : null,
    snapshot_config_version: e.trace.work_order ? e.trace.work_order.config_version_snapshot : null,
    active_config_id: e.trace.active_config_now ? e.trace.active_config_now.id : (e.trace.snapshot_config ? (e.trace.snapshot_config.id) : null),
    active_config_cycle_days: e.trace.active_config_now ? e.trace.active_config_now.cycle_days : (e.trace.snapshot_config ? e.trace.snapshot_config.cycle_days : null),
    active_config_version: e.trace.active_config_now ? e.trace.active_config_now.version : null,
    last_calibrated_date: e.base_calculation.last_calibrated_date,
    next_due_date: e.base_calculation.next_due_date,
    days_overdue: e.base_calculation.is_overdue ? e.base_calculation.days_overdue : 0,
    is_overdue: e.base_calculation.is_overdue,
    open_order_id: e.open_work_order ? e.open_work_order.id : null,
    open_order_status: e.open_work_order ? e.open_work_order.status : null,
    open_order_technician_id: e.open_work_order ? e.open_work_order.technician_id : null
  }));
}

function buildReconciliationView(asOfDate, includeNonOverdue = false) {
  const explanations = getAllOverdueExplanations(asOfDate);

  let filtered = explanations;
  if (!includeNonOverdue) {
    filtered = explanations.filter(e =>
      e.base_calculation.is_overdue || e.open_work_order
    );
  }

  const totalInstruments = explanations.length;
  const shownCount = filtered.length;
  const overdueCount = filtered.filter(e => e.base_calculation.is_overdue).length;
  const withOpenOrderCount = filtered.filter(e => e.open_work_order).length;
  const unavailableCount = filtered.filter(e => e.trace.cycle_source === 'unavailable').length;

  const cycleSourceBreakdown = {};
  for (const e of filtered) {
    const src = e.trace.cycle_source;
    cycleSourceBreakdown[src] = (cycleSourceBreakdown[src] || 0) + 1;
  }

  const reasonCodeBreakdown = {};
  for (const e of filtered) {
    const code = e.trace.reason.code;
    reasonCodeBreakdown[code] = (reasonCodeBreakdown[code] || 0) + 1;
  }

  const cycleMismatchDetails = [];
  for (const e of filtered) {
    if (e.trace.cycle_source !== 'work_order_snapshot') continue;
    if (!e.trace.work_order || !e.trace.active_config_now) continue;

    const snapshotCycle = e.trace.work_order.cycle_days_snapshot;
    const activeCycle = e.trace.active_config_now.cycle_days;
    const snapshotConfigId = e.trace.work_order.config_id_snapshot;
    const activeConfigId = e.trace.active_config_now.id;

    if (snapshotCycle !== activeCycle || snapshotConfigId !== activeConfigId) {
      cycleMismatchDetails.push({
        instrument_id: e.instrument_id,
        instrument_name: e.instrument_name,
        serial_number: e.serial_number,
        work_order_id: e.trace.work_order.id,
        verified_date: e.trace.work_order.verified_date ? e.trace.work_order.verified_date.split('T')[0] : null,
        snapshot_config: {
          id: snapshotConfigId,
          version: e.trace.work_order.config_version_snapshot,
          cycle_days: snapshotCycle
        },
        active_config: {
          id: activeConfigId,
          version: e.trace.active_config_now.version,
          cycle_days: activeCycle
        },
        cycle_diff_days: activeCycle - snapshotCycle,
        applied_cycle_days: e.base_calculation.applied_cycle_days,
        next_due_date: e.base_calculation.next_due_date,
        is_overdue: e.base_calculation.is_overdue,
        days_overdue: e.base_calculation.days_overdue,
        mismatch_reason: e.trace.active_config_now.version_diff_note ||
          (snapshotConfigId !== activeConfigId
            ? '工单创建后配置版本已切换，计算仍按创建时快照'
            : '快照周期与当前活跃周期不一致')
      });
    }
  }

  const openOrdersSummary = [];
  for (const e of filtered) {
    if (!e.open_work_order) continue;
    openOrdersSummary.push({
      instrument_id: e.instrument_id,
      instrument_name: e.instrument_name,
      serial_number: e.serial_number,
      open_work_order: {
        id: e.open_work_order.id,
        status: e.open_work_order.status,
        created_at: e.open_work_order.created_at,
        technician_id: e.open_work_order.technician_id,
        scheduled_start: e.open_work_order.scheduled_start,
        scheduled_end: e.open_work_order.scheduled_end
      },
      cycle_source_used_for_calc: e.trace.cycle_source,
      cycle_source_readable: e.trace.cycle_source_readable,
      open_order_participation: '未参与 next_due_date 计算，仅作参考展示',
      participation_note: e.open_work_order.warning || '未完成工单只展示不参与计算'
    });
  }

  const bySourceGroups = {
    work_order_snapshot: filtered.filter(e => e.trace.cycle_source === 'work_order_snapshot').map(e => ({
      instrument_id: e.instrument_id,
      instrument_name: e.instrument_name,
      serial_number: e.serial_number,
      applied_cycle_days: e.base_calculation.applied_cycle_days,
      last_calibrated_date: e.base_calculation.last_calibrated_date,
      next_due_date: e.base_calculation.next_due_date,
      is_overdue: e.base_calculation.is_overdue,
      days_overdue: e.base_calculation.days_overdue,
      work_order_id: e.trace.work_order?.id,
      verified_date: e.trace.work_order?.verified_date ? e.trace.work_order.verified_date.split('T')[0] : null,
      snapshot_config_id: e.trace.work_order?.config_id_snapshot,
      snapshot_config_version: e.trace.work_order?.config_version_snapshot
    })),
    active_config_fallback: filtered.filter(e => e.trace.cycle_source === 'active_config_fallback').map(e => ({
      instrument_id: e.instrument_id,
      instrument_name: e.instrument_name,
      serial_number: e.serial_number,
      applied_cycle_days: e.base_calculation.applied_cycle_days,
      next_due_date: e.base_calculation.next_due_date,
      is_overdue: e.base_calculation.is_overdue,
      days_overdue: e.base_calculation.days_overdue,
      fallback_reason_code: e.trace.reason.code,
      fallback_reason_message: e.trace.reason.message,
      active_config_id: e.trace.active_config_now?.id,
      active_config_version: e.trace.active_config_now?.version
    })),
    unavailable: filtered.filter(e => e.trace.cycle_source === 'unavailable').map(e => ({
      instrument_id: e.instrument_id,
      instrument_name: e.instrument_name,
      serial_number: e.serial_number,
      unavailable_reason_code: e.trace.reason.code,
      unavailable_reason_message: e.trace.reason.message,
      has_open_work_order: !!e.open_work_order
    }))
  };

  return {
    summary: {
      as_of: asOfDate,
      total_instruments: totalInstruments,
      shown_instruments: shownCount,
      overdue_count: overdueCount,
      with_open_order_count: withOpenOrderCount,
      unavailable_count: unavailableCount,
      include_non_overdue: includeNonOverdue
    },
    cycle_source_breakdown: cycleSourceBreakdown,
    reason_code_breakdown: reasonCodeBreakdown,
    cycle_mismatch: {
      count: cycleMismatchDetails.length,
      note: '快照周期与当前活跃周期不一致的仪器列表。计算始终用工单创建时的快照，活跃配置仅作参考展示。',
      details: cycleMismatchDetails
    },
    open_orders: {
      count: openOrdersSummary.length,
      participation_rule: '未完成工单（created/assigned/completed/returned）只展示不参与计算，next_due_date 仅基于已复核工单或活跃配置。',
      details: openOrdersSummary
    },
    grouped_instruments: bySourceGroups
  };
}

module.exports = {
  buildInstrumentOverdueExplanation,
  getAllOverdueExplanations,
  getOverdueListCompact,
  buildReconciliationView
};
