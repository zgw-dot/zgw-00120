const express = require('express');
const { queryOne } = require('../dbHelper');
const { AppError } = require('../middleware/errorHandler');
const {
  getAllOverdueExplanations,
  getOverdueListCompact,
  buildInstrumentOverdueExplanation,
  buildReconciliationView
} = require('../overdueTrace');

const router = express.Router();

router.get('/', (req, res) => {
  const { as_of } = req.query;
  const asOfDate = as_of || new Date().toISOString().split('T')[0];

  const compactList = getOverdueListCompact(asOfDate);
  const filtered = compactList.filter(item => item.is_overdue || item.open_order_id);

  const totalInstruments = queryOne(
    "SELECT COUNT(*) as cnt FROM instruments WHERE status = 'active'"
  ).cnt;

  res.json({
    data: filtered,
    meta: {
      as_of: asOfDate,
      total_instruments: totalInstruments,
      overdue_count: filtered.filter(i => i.is_overdue).length,
      with_open_order_count: filtered.filter(i => i.open_order_id).length,
      note: '使用 /api/overdue/explain 获取每条记录的完整规则追溯与审计信息'
    }
  });
});

router.get('/explain', (req, res) => {
  const { as_of, instrument_id, include_non_overdue } = req.query;
  const asOfDate = as_of || new Date().toISOString().split('T')[0];

  let explanations = getAllOverdueExplanations(asOfDate);

  if (instrument_id) {
    explanations = explanations.filter(e => e.instrument_id === instrument_id);
  }

  if (include_non_overdue !== 'true' && include_non_overdue !== '1') {
    explanations = explanations.filter(e =>
      e.base_calculation.is_overdue || e.open_work_order
    );
  }

  const totalInstruments = queryOne(
    "SELECT COUNT(*) as cnt FROM instruments WHERE status = 'active'"
  ).cnt;

  const sourceBreakdown = {};
  for (const e of explanations) {
    const src = e.trace.cycle_source;
    sourceBreakdown[src] = (sourceBreakdown[src] || 0) + 1;
  }

  res.json({
    data: explanations,
    meta: {
      as_of: asOfDate,
      total_instruments: totalInstruments,
      shown_count: explanations.length,
      overdue_count: explanations.filter(e => e.base_calculation.is_overdue).length,
      with_open_order_count: explanations.filter(e => e.open_work_order).length,
      cycle_source_breakdown: sourceBreakdown,
      fields_legend: {
        base_calculation: '最终计算结果（next_due_date、is_overdue 等）',
        trace: '完整追溯链路，包含 cycle_source、工单、配置、原因、审计ID、导入信息',
        open_work_order: '未完成工单参考信息（独立字段，未参与计算）'
      }
    }
  });
});

router.get('/explain/:instrumentId', (req, res) => {
  const { as_of } = req.query;
  const asOfDate = as_of || new Date().toISOString().split('T')[0];
  const instrumentId = req.params.instrumentId;

  const inst = queryOne('SELECT * FROM instruments WHERE id = ?', [instrumentId]);
  if (!inst) {
    throw new AppError(`Instrument not found: id=${instrumentId}`, 404, 'NOT_FOUND');
  }

  const explanation = buildInstrumentOverdueExplanation(inst, asOfDate);

  res.json({
    data: explanation,
    meta: {
      as_of: asOfDate,
      requested_instrument_id: instrumentId
    }
  });
});

router.get('/reconciliation', (req, res) => {
  const { as_of, include_non_overdue } = req.query;
  const asOfDate = as_of || new Date().toISOString().split('T')[0];
  const includeNonOverdue = include_non_overdue === 'true' || include_non_overdue === '1';

  const result = buildReconciliationView(asOfDate, includeNonOverdue);

  res.json({
    data: result,
    meta: {
      as_of: asOfDate,
      include_non_overdue: includeNonOverdue,
      endpoint_note: '批量对账视图：一眼看出各仪器按什么规则计算、快照周期与活跃周期是否一致、未完成工单的展示规则',
      sections: {
        summary: '汇总计数（仪器总数、展示数、逾期数、有未完成工单数、无法计算数）',
        cycle_source_breakdown: '按 cycle_source 分组计数（work_order_snapshot / active_config_fallback / unavailable）',
        reason_code_breakdown: '按 reason.code 分组计数（更细粒度的原因分类）',
        cycle_mismatch: '快照周期与当前活跃周期不一致的仪器明细（仅 work_order_snapshot 来源可能出现）',
        open_orders: '未完成工单清单，明确标注"只展示不参与计算"规则',
        grouped_instruments: '按 cycle_source 分组的完整仪器明细列表'
      }
    }
  });
});

module.exports = router;
