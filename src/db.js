const initSqlJs = require('sql.js');
const fs = require('fs');
const path = require('path');

const DATA_DIR = path.join(__dirname, '..', 'data');
const DB_PATH = path.join(DATA_DIR, 'calibration.db');

if (!fs.existsSync(DATA_DIR)) {
  fs.mkdirSync(DATA_DIR, { recursive: true });
}

let db = null;

function saveToFile() {
  if (!db) return;
  const data = db.export();
  const buffer = Buffer.from(data);
  fs.writeFileSync(DB_PATH, buffer);
}

function loadFromFile() {
  if (fs.existsSync(DB_PATH)) {
    const buffer = fs.readFileSync(DB_PATH);
    return new Uint8Array(buffer);
  }
  return null;
}

const SCHEMA = `
  CREATE TABLE IF NOT EXISTS instruments (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    model TEXT NOT NULL DEFAULT '',
    serial_number TEXT UNIQUE NOT NULL,
    location TEXT NOT NULL DEFAULT '',
    category TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'active',
    description TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  );

  CREATE TABLE IF NOT EXISTS calibration_configs (
    id TEXT PRIMARY KEY,
    instrument_id TEXT NOT NULL,
    cycle_days INTEGER NOT NULL,
    tolerance TEXT NOT NULL DEFAULT '',
    standard TEXT NOT NULL DEFAULT '',
    version INTEGER NOT NULL DEFAULT 1,
    is_active INTEGER NOT NULL DEFAULT 1,
    effective_from TEXT NOT NULL,
    created_at TEXT NOT NULL,
    FOREIGN KEY (instrument_id) REFERENCES instruments(id)
  );

  CREATE INDEX IF NOT EXISTS idx_configs_instrument ON calibration_configs(instrument_id);
  CREATE INDEX IF NOT EXISTS idx_configs_active ON calibration_configs(instrument_id, is_active);

  CREATE TABLE IF NOT EXISTS technicians (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    employee_id TEXT UNIQUE NOT NULL,
    title TEXT NOT NULL DEFAULT '',
    phone TEXT NOT NULL DEFAULT '',
    email TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'active',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  );

  CREATE TABLE IF NOT EXISTS technician_schedules (
    id TEXT PRIMARY KEY,
    technician_id TEXT NOT NULL,
    start_time TEXT NOT NULL,
    end_time TEXT NOT NULL,
    shift_type TEXT NOT NULL DEFAULT 'regular',
    notes TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,
    FOREIGN KEY (technician_id) REFERENCES technicians(id)
  );

  CREATE INDEX IF NOT EXISTS idx_schedule_tech ON technician_schedules(technician_id);
  CREATE INDEX IF NOT EXISTS idx_schedule_start ON technician_schedules(start_time);

  CREATE TABLE IF NOT EXISTS work_orders (
    id TEXT PRIMARY KEY,
    instrument_id TEXT NOT NULL,
    config_id TEXT NOT NULL,
    config_version INTEGER NOT NULL,
    cycle_days_snapshot INTEGER NOT NULL,
    technician_id TEXT,
    status TEXT NOT NULL DEFAULT 'created',
    planned_date TEXT,
    scheduled_start TEXT,
    scheduled_end TEXT,
    assigned_date TEXT,
    completed_date TEXT,
    verified_date TEXT,
    result TEXT NOT NULL DEFAULT '',
    deviation TEXT NOT NULL DEFAULT '',
    certificate_no TEXT NOT NULL DEFAULT '',
    notes TEXT NOT NULL DEFAULT '',
    created_by TEXT NOT NULL DEFAULT 'system',
    verified_by TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY (instrument_id) REFERENCES instruments(id),
    FOREIGN KEY (technician_id) REFERENCES technicians(id)
  );

  CREATE INDEX IF NOT EXISTS idx_orders_instrument ON work_orders(instrument_id);
  CREATE INDEX IF NOT EXISTS idx_orders_status ON work_orders(status);
  CREATE INDEX IF NOT EXISTS idx_orders_technician ON work_orders(technician_id);
  CREATE INDEX IF NOT EXISTS idx_orders_planned ON work_orders(planned_date);
  CREATE INDEX IF NOT EXISTS idx_orders_sched_start ON work_orders(scheduled_start);

  CREATE TABLE IF NOT EXISTS audit_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    event_type TEXT NOT NULL,
    entity_type TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    old_values TEXT,
    new_values TEXT,
    operator TEXT NOT NULL DEFAULT 'system',
    timestamp TEXT NOT NULL
  );

  CREATE INDEX IF NOT EXISTS idx_audit_entity ON audit_events(entity_type, entity_id);
  CREATE INDEX IF NOT EXISTS idx_audit_type ON audit_events(event_type);
  CREATE INDEX IF NOT EXISTS idx_audit_timestamp ON audit_events(timestamp);
`;

async function initDatabase() {
  const SQL = await initSqlJs();
  const existingData = loadFromFile();
  if (existingData) {
    db = new SQL.Database(existingData);
  } else {
    db = new SQL.Database();
  }
  db.run(SCHEMA);
  saveToFile();
  return db;
}

function getDb() {
  return db;
}

module.exports = { initDatabase, getDb, saveToFile };
