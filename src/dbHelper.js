const { getDb, saveToFile } = require('./db');

let _inTransaction = false;

function queryAll(sql, params = []) {
  const db = getDb();
  const stmt = db.prepare(sql);
  try {
    if (params.length > 0) {
      const safeParams = params.map(p => p === undefined ? null : p);
      stmt.bind(safeParams);
    }
    const rows = [];
    while (stmt.step()) {
      rows.push(stmt.getAsObject());
    }
    return rows;
  } finally {
    stmt.free();
  }
}

function queryOne(sql, params = []) {
  const rows = queryAll(sql, params);
  return rows.length > 0 ? rows[0] : undefined;
}

function run(sql, params = []) {
  const db = getDb();
  const safeParams = params.map(p => p === undefined ? null : p);
  db.run(sql, safeParams);
  const changes = db.getRowsModified();
  const lastInsertRowId = queryOne('SELECT last_insert_rowid() as id').id;
  if (!_inTransaction) {
    saveToFile();
  }
  return { changes, lastInsertRowId };
}

function runInTransaction(fn) {
  const db = getDb();
  db.run('BEGIN TRANSACTION');
  _inTransaction = true;
  try {
    const result = fn();
    db.run('COMMIT');
    _inTransaction = false;
    saveToFile();
    return result;
  } catch (e) {
    _inTransaction = false;
    try { db.run('ROLLBACK'); } catch (_) {}
    throw e;
  }
}

module.exports = { queryAll, queryOne, run, runInTransaction };
