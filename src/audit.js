const { getDb, saveToFile } = require('./db');

function recordAudit(eventType, entityType, entityId, oldValues, newValues, operator = 'system') {
  const db = getDb();
  db.run(
    `INSERT INTO audit_events (event_type, entity_type, entity_id, old_values, new_values, operator, timestamp)
     VALUES (?, ?, ?, ?, ?, ?, ?)`,
    [eventType, entityType, entityId,
      oldValues ? JSON.stringify(oldValues) : null,
      newValues ? JSON.stringify(newValues) : null,
      operator, new Date().toISOString()]
  );
  saveToFile();
}

module.exports = { recordAudit };
