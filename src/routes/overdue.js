const express = require('express');
const { queryAll, queryOne } = require('../dbHelper');

const router = express.Router();

router.get('/', (req, res) => {
  const { as_of } = req.query;
  const asOfDate = as_of || new Date().toISOString().split('T')[0];

  const instruments = queryAll('SELECT * FROM instruments WHERE status = ?', ['active']);
  const overdueList = [];

  for (const inst of instruments) {
    const activeConfig = queryOne('SELECT * FROM calibration_configs WHERE instrument_id = ? AND is_active = 1', [inst.id]);
    if (!activeConfig) continue;

    const lastOrder = queryOne(
      "SELECT * FROM work_orders WHERE instrument_id = ? AND status = 'verified' ORDER BY verified_date DESC LIMIT 1",
      [inst.id]
    );

    const openOrder = queryOne(
      "SELECT * FROM work_orders WHERE instrument_id = ? AND status IN ('created','assigned','completed','returned') ORDER BY created_at DESC LIMIT 1",
      [inst.id]
    );

    let nextDueDate;
    let lastCalibratedDate;
    let daysOverdue = 0;
    let isOverdue = false;
    let appliedCycleDays;
    let cycleSource;

    if (lastOrder) {
      lastCalibratedDate = lastOrder.verified_date ? lastOrder.verified_date.split('T')[0] : lastOrder.completed_date?.split('T')[0];
      if (lastCalibratedDate) {
        appliedCycleDays = lastOrder.cycle_days_snapshot;
        cycleSource = 'work_order_snapshot';
        const d = new Date(lastCalibratedDate);
        d.setDate(d.getDate() + appliedCycleDays);
        nextDueDate = d.toISOString().split('T')[0];
      }
    } else {
      appliedCycleDays = activeConfig.cycle_days;
      cycleSource = 'active_config';
      nextDueDate = inst.created_at.split('T')[0];
    }

    if (nextDueDate && asOfDate > nextDueDate) {
      const due = new Date(nextDueDate);
      const asOf = new Date(asOfDate);
      daysOverdue = Math.floor((asOf - due) / (1000 * 60 * 60 * 24));
      isOverdue = true;
    }


    if (isOverdue || openOrder) {
      overdueList.push({
        instrument_id: inst.id,
        instrument_name: inst.name,
        serial_number: inst.serial_number,
        category: inst.category,
        location: inst.location,
        applied_cycle_days: appliedCycleDays,
        cycle_source: cycleSource,
        snapshot_config_id: lastOrder ? lastOrder.config_id : null,
        snapshot_config_version: lastOrder ? lastOrder.config_version : null,
        active_config_id: activeConfig.id,
        active_config_cycle_days: activeConfig.cycle_days,
        active_config_version: activeConfig.version,
        last_calibrated_date: lastCalibratedDate || null,
        next_due_date: nextDueDate || null,
        days_overdue: isOverdue ? daysOverdue : 0,
        is_overdue: isOverdue,
        open_order_id: openOrder ? openOrder.id : null,
        open_order_status: openOrder ? openOrder.status : null,
        open_order_technician_id: openOrder ? openOrder.technician_id : null
      });
    }
  }

  overdueList.sort((a, b) => b.days_overdue - a.days_overdue);

  res.json({
    data: overdueList,
    meta: {
      as_of: asOfDate,
      total_instruments: instruments.length,
      overdue_count: overdueList.filter(i => i.is_overdue).length,
      with_open_order_count: overdueList.filter(i => i.open_order_id).length
    }
  });
});

module.exports = router;
