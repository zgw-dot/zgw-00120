const express = require('express');
const morgan = require('morgan');
const path = require('path');

const { initDatabase } = require('./db');
const { errorHandler, notFoundHandler } = require('./middleware/errorHandler');

const instrumentsRouter = require('./routes/instruments');
const configsRouter = require('./routes/configs');
const techniciansRouter = require('./routes/technicians');
const workOrdersRouter = require('./routes/workorders');
const overdueRouter = require('./routes/overdue');
const auditRouter = require('./routes/audit');
const dataRouter = require('./routes/data');

const app = express();
const PORT = process.env.PORT || 3000;

app.use(morgan('dev'));
app.use(express.json({ limit: '10mb' }));

app.get('/', (req, res) => {
  res.json({
    service: 'Lab Calibration Scheduler',
    version: '1.0.0',
    endpoints: {
      instruments: '/api/instruments',
      configs: '/api/configs',
      technicians: '/api/technicians',
      workOrders: '/api/work-orders',
      overdue: '/api/overdue',
      overdueExplain: '/api/overdue/explain',
      overdueExplainByInstrument: '/api/overdue/explain/:instrumentId',
      audit: '/api/audit',
      dataExport: '/api/data/export',
      dataImport: '/api/data/import'
    }
  });
});

app.get('/health', (req, res) => {
  res.json({ status: 'ok', timestamp: new Date().toISOString() });
});

app.use('/api/instruments', instrumentsRouter);
app.use('/api/configs', configsRouter);
app.use('/api/technicians', techniciansRouter);
app.use('/api/work-orders', workOrdersRouter);
app.use('/api/overdue', overdueRouter);
app.use('/api/audit', auditRouter);
app.use('/api/data', dataRouter);

app.use(notFoundHandler);
app.use(errorHandler);

async function start() {
  await initDatabase();
  app.listen(PORT, () => {
    console.log(`[Lab Calibration Scheduler] Server running on http://localhost:${PORT}`);
    console.log(`[Lab Calibration Scheduler] API base: http://localhost:${PORT}/api/`);
    console.log(`[Lab Calibration Scheduler] Data file: ${path.join(__dirname, '..', 'data', 'calibration.db')}`);
  });
}

start().catch(err => {
  console.error('Failed to start server:', err);
  process.exit(1);
});
