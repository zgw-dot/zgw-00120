const express = require('express');
const { queryAll } = require('../dbHelper');

const router = express.Router();

router.get('/', (req, res) => {
  const { event_type, entity_type, entity_id, start_date, end_date, limit, offset } = req.query;

  let sql = 'SELECT * FROM audit_events WHERE 1=1';
  const params = [];

  if (event_type) { sql += ' AND event_type = ?'; params.push(event_type); }
  if (entity_type) { sql += ' AND entity_type = ?'; params.push(entity_type); }
  if (entity_id) { sql += ' AND entity_id = ?'; params.push(entity_id); }
  if (start_date) { sql += ' AND timestamp >= ?'; params.push(start_date); }
  if (end_date) { sql += ' AND timestamp <= ?'; params.push(end_date); }

  sql += ' ORDER BY id DESC';

  const lim = Math.min(parseInt(limit) || 100, 1000);
  const off = parseInt(offset) || 0;
  sql += ' LIMIT ? OFFSET ?';
  params.push(lim, off);

  const rows = queryAll(sql, params);

  const parsed = rows.map(r => ({
    ...r,
    old_values: r.old_values ? JSON.parse(r.old_values) : null,
    new_values: r.new_values ? JSON.parse(r.new_values) : null
  }));

  res.json({ data: parsed, meta: { limit: lim, offset: off } });
});

router.get('/entity/:entityType/:entityId', (req, res) => {
  const rows = queryAll(
    'SELECT * FROM audit_events WHERE entity_type = ? AND entity_id = ? ORDER BY id ASC',
    [req.params.entityType, req.params.entityId]
  );

  const parsed = rows.map(r => ({
    ...r,
    old_values: r.old_values ? JSON.parse(r.old_values) : null,
    new_values: r.new_values ? JSON.parse(r.new_values) : null
  }));

  res.json({ data: parsed });
});

module.exports = router;
