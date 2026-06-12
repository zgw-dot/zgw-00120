# Lab Calibration Scheduler — 实验室仪器校准排期服务

基于 Node.js + Express + SQLite (sql.js) 的本地 REST API 服务，管理仪器台账、校准周期配置、技师排班和校准工单。

## 功能概述

| 模块 | API 前缀 | 核心能力 |
|---|---|---|
| 仪器台账 | `/api/instruments` | CRUD、序列号唯一性校验 |
| 校准周期配置 | `/api/configs` | 版本化配置，历史留痕，修改只影响后续工单 |
| 技师排班 | `/api/technicians` | 技师管理 + datetime 排班，冲突检测 |
| 校准工单 | `/api/work-orders` | 创建→指派→完成→复核 / 退回重开，状态机严格校验 |
| 逾期清单 | `/api/overdue` | 基于配置周期计算逾期，结果重启后可复现；`/explain` 接口提供完整规则追溯；`/reconciliation` 提供批量对账视图 |
| 审计事件 | `/api/audit` | 全量操作留痕，按实体/时间查询 |
| 数据导入导出 | `/api/data` | JSON 全量导出/导入，含校验（负数周期拦截） |

## 快速开始

```bash
npm install
npm start
# 服务启动在 http://localhost:3000
```

开发模式（自动重启）：

```bash
npm run dev
```

## 数据持久化

SQLite 数据库文件：`data/calibration.db`（首次启动自动创建）。

> 服务重启后所有数据（仪器、配置、工单、审计日志、逾期计算结果）均可复现。

## API 接口一览

### 仪器台账

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/instruments` | 列表（支持 `?status=active` 筛选） |
| GET | `/api/instruments/:id` | 详情 |
| POST | `/api/instruments` | 新增 |
| PUT | `/api/instruments/:id` | 更新 |
| DELETE | `/api/instruments/:id` | 删除（有未完成工单时拒绝） |

**POST/PUT 请求体字段**：`name`(必填), `serial_number`(必填,唯一), `model`, `manufacturer`, `location`, `category`, `description`, `status`

### 校准周期配置

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/configs` | 列表（`?instrument_id=xxx&is_active=true`） |
| GET | `/api/configs/:id` | 详情 |
| POST | `/api/configs` | 新增（自动递增版本，旧配置标记为不活跃） |
| PUT | `/api/configs/:id` | 更新 |
| GET | `/api/configs/instrument/:instrumentId/history` | 某仪器的配置版本历史 |

**POST 请求体字段**：`instrument_id`(必填), `cycle_days`(必填,正整数), `tolerance`, `standard`, `description`

> 配置新增时自动递增版本号，旧版本标记 `is_active=0`。工单创建时快照当前 `cycle_days`，历史计算留痕不受后续配置调整影响。

### 技师

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/technicians` | 列表 |
| GET | `/api/technicians/:id` | 详情 |
| POST | `/api/technicians` | 新增 |
| PUT | `/api/technicians/:id` | 更新 |
| DELETE | `/api/technicians/:id` | 删除 |
| GET | `/api/technicians/:id/schedules` | 排班列表（`?start_date=...&end_date=...`） |
| POST | `/api/technicians/:id/schedules` | 新增排班（时间冲突自动拦截） |
| DELETE | `/api/technicians/:techId/schedules/:scheduleId` | 删除排班 |

**POST /schedules 请求体**：`start_time`(必填,ISO datetime), `end_time`(必填,ISO datetime), `shift_type`, `notes`

> 排班使用 ISO datetime 范围表示，重叠检测自动拦截。

### 校准工单

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/work-orders` | 列表（`?status=assigned&instrument_id=xxx`） |
| GET | `/api/work-orders/:id` | 详情 |
| POST | `/api/work-orders` | 创建工单 |
| POST | `/api/work-orders/:id/assign` | 指派技师 |
| POST | `/api/work-orders/:id/complete` | 完成 |
| POST | `/api/work-orders/:id/verify` | 复核通过 |
| POST | `/api/work-orders/:id/return` | 退回重开 |
| POST | `/api/work-orders/:id/reassign` | 重新指派（退回后） |

**创建工单**：`instrument_id`(必填), `planned_date`, `priority`, `notes`, `created_by`

**指派工单**：`technician_id`(必填), `scheduled_start`(必填,ISO datetime), `scheduled_end`(必填,ISO datetime)

> 指派时检测：1) 技师是否有覆盖该时间段的排班 2) 是否与已有工单时间重叠

**完成工单**：`result`(必填), `deviation`, `certificate_no`, `notes`

**复核工单**：`verified_by`

**退回工单**：`notes`

**重新指派**：`technician_id`(必填), `scheduled_start`(可选), `scheduled_end`(可选)

### 逾期清单

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/overdue` | 逾期清单（`?as_of=2026-06-12` 指定基准日期） |
| GET | `/api/overdue/explain` | 逾期规则追溯（完整解释每条结果按哪条规则算出） |
| GET | `/api/overdue/explain/:instrumentId` | 单仪器逾期规则追溯 |
| GET | `/api/overdue/reconciliation` | 批量对账视图（汇总计数 + 分组 + 不一致明细 + 未完成工单说明） |

> 计算逻辑：对每个活跃仪器，取最近 verified 工单的 verified_date + cycle_days_snapshot，若超过基准日期则标记逾期。

#### 逾期规则追溯 (`/api/overdue/explain`)

**查询参数**：

| 参数 | 说明 |
|---|---|
| `as_of` | 基准日期，默认今天 |
| `instrument_id` | 筛选指定仪器 |
| `include_non_overdue` | `true` 时返回所有仪器（含未逾期的），默认只返回逾期或有未完成工单的 |

**返回结构**（每条记录）：

```json
{
  "instrument_id": "uuid",
  "instrument_name": "Pressure Gauge A",
  "serial_number": "SN-001",
  "base_calculation": {
    "next_due_date": "2026-07-12",
    "last_calibrated_date": "2026-06-12",
    "applied_cycle_days": 30,
    "as_of": "2026-08-01",
    "is_overdue": true,
    "days_overdue": 20
  },
  "trace": {
    "cycle_source": "work_order_snapshot",
    "cycle_source_readable": "最近一次已复核工单的 cycle_days 快照",
    "work_order": {
      "id": "uuid",
      "status": "verified",
      "verified_date": "2026-06-12T10:00:00.000Z",
      "completed_date": "2026-06-12T09:00:00.000Z",
      "cycle_days_snapshot": 30,
      "config_id_snapshot": "cfg-uuid",
      "config_version_snapshot": 1,
      "returned_count_before_verify": 0,
      "verified_by": "QA Manager"
    },
    "snapshot_config": {
      "id": "cfg-uuid",
      "version": 1,
      "cycle_days": 30,
      "is_active_now": false,
      "note": "该配置已被新版本替代，仅用于追溯历史计算依据"
    },
    "active_config_now": {
      "id": "cfg-v2-uuid",
      "version": 2,
      "cycle_days": 60,
      "version_diff_note": "当前活跃配置版本已更新为 v2(cycle=60天)，但历史计算仍按工单快照执行"
    },
    "reason": {
      "code": "USING_LAST_VERIFIED_WORK_ORDER",
      "message": "基于最近一次复核通过的工单（uuid）按快照周期 30 天计算：2026-06-12 + 30天 = 2026-07-12",
      "fallback_used": false
    },
    "audit_event_ids": {
      "work_order_create": 15,
      "work_order_verify": 18,
      "snapshot_config_create": 12,
      "related_all": [12, 15, 16, 18, 20]
    },
    "import_info": {
      "is_imported": false,
      "evidence": "SYSTEM_CREATED",
      "related_audit_id": null,
      "data_integrity": "工单 ID(uuid)、配置 ID(uuid) 均为导入时保留的原始 ID，追溯链接保持完整"
    }
  },
  "open_work_order": null
}
```

**`cycle_source` 取值说明**：

| cycle_source | 含义 | reason.code |
|---|---|---|
| `work_order_snapshot` | 基于最近已复核工单的快照周期计算 | `USING_LAST_VERIFIED_WORK_ORDER` |
| `active_config_fallback` | 无已复核工单，走活跃配置兜底 | `NO_WORK_ORDERS_AT_ALL` / `ONLY_OPEN_ORDERS` / `NO_VERIFIED_ORDER` |
| `unavailable` | 无活跃配置，无法计算 | `NO_ACTIVE_CONFIG` |

**`import_info.evidence` 取值说明**：

| evidence | 含义 |
|---|---|
| `SYSTEM_CREATED` | 系统正常创建（非导入） |
| `ENTITY_IMPORT_AUDIT` | 有 ENTITY_IMPORT 审计事件直接证明为导入数据 |
| `SYSTEM_IMPORT_PROXIMITY` | 无直接 ENTITY_IMPORT 事件，但创建时间与系统 IMPORT 事件吻合 |

**边界例子**：

1. **配置版本切换**：仪器有 v1(30天) 已复核工单，之后配置改为 v2(60天)。explain 的 `applied_cycle_days` 仍为 30（快照），`active_config_now.cycle_days=60` 仅做参考展示，不参与计算。

2. **退回重开**：工单创建时快照 cycle=14，期间配置切换到 21 天，工单退回后重新完成并复核。explain 的 `returned_count_before_verify=1`，`applied_cycle_days=14`（仍按创建时的快照）。

3. **打开工单 + 历史复核**：仪器有已复核工单 WO-1，同时存在未完成工单 WO-2。explain 的 `trace.work_order` 指向 WO-1（已复核），`open_work_order` 指向 WO-2 并标注"未参与计算"。

4. **无历史复核**：从未创建工单 -> reason.code=`NO_WORK_ORDERS_AT_ALL`；有工单但未复核 -> reason.code=`ONLY_OPEN_ORDERS`。两者均走 `active_config_fallback`，按 `instrument.created_at + active_config.cycle_days` 计算。

5. **导出再导入**：导入后每个实体自动追加 `ENTITY_IMPORT` 审计事件。explain 的 `import_info.is_imported=true`，`work_order.id` 和 `config_id_snapshot` 保持原值，追溯链路完整。

6. **服务重启**：explain 完全基于数据库实时查询计算，无缓存状态，重启后结果不变。多次查询结果完全一致（确定性验证）。

#### 批量对账视图 (`/api/overdue/reconciliation`)

**查询参数**：

| 参数 | 类型 | 说明 |
|---|---|---|
| `as_of` | string | 基准日期 `YYYY-MM-DD`，默认今天 |
| `include_non_overdue` | string | `"true"` 时返回所有仪器（含未逾期），默认只返回逾期或有未完成工单的 |

**顶层返回字段**：

| 字段 | 说明 |
|---|---|
| `summary` | 汇总计数 |
| `cycle_source_breakdown` | 周期来源分组计数 |
| `reason_code_breakdown` | 原因代码分组计数 |
| `cycle_mismatch` | 快照周期与活跃周期不一致明细 |
| `open_orders` | 未完成工单明细 |
| `grouped_instruments` | 按来源分组的仪器完整列表 |

**`summary` 字段**：

| 字段 | 说明 |
|---|---|
| `as_of` | 基准日期 |
| `total_instruments` | 仪器总数 |
| `shown_instruments` | 本次展示的仪器数 |
| `overdue_count` | 逾期仪器数 |
| `with_open_order_count` | 有未完成工单的仪器数 |
| `unavailable_count` | 无法计算（无活跃配置）的仪器数 |
| `include_non_overdue` | 本次请求的 include_non_overdue 取值 |

**`cycle_source_breakdown` 字段**（key 为 cycle_source，value 为计数）：

| key | 含义 |
|---|---|
| `work_order_snapshot` | 按最近已复核工单快照周期计算 |
| `active_config_fallback` | 无已复核工单，走活跃配置兜底 |
| `unavailable` | 无活跃配置，无法计算 |

**`grouped_instruments` 三组的关键字段**：

| 组 | 关键字段 |
|---|---|
| `work_order_snapshot` | `instrument_id`, `applied_cycle_days`, `next_due_date`, `work_order_id`, `verified_date`, `snapshot_config_id`, `snapshot_config_version` |
| `active_config_fallback` | `instrument_id`, `applied_cycle_days`, `next_due_date`, `fallback_reason_code`, `fallback_reason_message`, `active_config_id` |
| `unavailable` | `instrument_id`, `unavailable_reason_code`, `unavailable_reason_message`, `has_open_work_order` |

**`cycle_mismatch` 字段**（仅快照周期与活跃周期不一致时才有记录）：

| 字段 | 说明 |
|---|---|
| `count` | 不一致的仪器数量 |
| `note` | 规则说明文字 |
| `details[].snapshot_config` | `{id, version, cycle_days}` 工单创建时快照 |
| `details[].active_config` | `{id, version, cycle_days}` 当前活跃配置 |
| `details[].cycle_diff_days` | 活跃周期减快照周期的差值 |
| `details[].applied_cycle_days` | 实际参与计算的周期（= 快照周期） |
| `details[].mismatch_reason` | 文字说明 |

**`open_orders` 字段**：

| 字段 | 说明 |
|---|---|
| `count` | 未完成工单数量 |
| `participation_rule` | **规则说明**：未完成工单（created/assigned/completed/returned）**只展示，不参与 next_due_date 计算**。next_due_date 仅基于已复核工单或活跃配置兜底。 |
| `details[].cycle_source_used_for_calc` | next_due_date 实际使用的计算来源 |
| `details[].open_order_participation` | 固定值：`未参与 next_due_date 计算，仅作参考展示` |
| `details[].participation_note` | 文字说明 |

**边界场景说明**：

1. **配置切换**：工单创建后配置版本更新，reconciliation 会将此仪器列入 `cycle_mismatch.details`，标注 snapshot/active 的 cycle 差，`applied_cycle_days` 始终取快照值。
2. **退回重开**：工单退回后重新完成并复核，`cycle_mismatch` 中 `snapshot_config.cycle_days` 仍为创建时原值，不受退回期间配置切换影响。
3. **无已复核工单**：仪器进入 `grouped_instruments.active_config_fallback` 组，`fallback_reason_code` 为 `NO_WORK_ORDERS_AT_ALL` 或 `ONLY_OPEN_ORDERS`。
4. **无活跃配置**：仪器进入 `grouped_instruments.unavailable` 组，`unavailable_reason_code` 为 `NO_ACTIVE_CONFIG`。
5. **未完成工单**：出现在 `open_orders.details` 中，明确标注"只展示，不参与计算"。其仪器仍可能出现在 `work_order_snapshot` 或 `active_config_fallback` 组中（按各自的 next_due_date 计算来源）。
6. **导出再导入**：导入后分组不变，`work_order_snapshot` 组的 `snapshot_config_id`、`snapshot_config_version`、`work_order_id` 与导入前一致。
7. **服务重启**：完全基于数据库计算，重启后同日查询结果字节级一致。

##### Reconciliation 接口验证命令

**1. curl (bash)**

```bash
# 默认：只返回逾期或有未完成工单的
curl -s "http://localhost:3000/api/overdue/reconciliation?as_of=2026-08-01" | python3 -m json.tool

# 返回所有仪器（含未逾期）
curl -s "http://localhost:3000/api/overdue/reconciliation?as_of=2026-08-01&include_non_overdue=true" | python3 -m json.tool
```

**2. Python requests**

```python
import requests

BASE = "http://localhost:3000/api"

r = requests.get(f"{BASE}/overdue/reconciliation", params={
    "as_of": "2026-08-01",
    "include_non_overdue": "true"
})
data = r.json()["data"]

print("total:", data["summary"]["total_instruments"])
print("overdue:", data["summary"]["overdue_count"])
print("unavailable:", data["summary"]["unavailable_count"])
print("breakdown:", data["cycle_source_breakdown"])
print("cycle_mismatch count:", data["cycle_mismatch"]["count"])
print("open_orders count:", data["open_orders"]["count"])
print("rule:", data["open_orders"]["participation_rule"])
```

**3. 完整测试脚本**

```powershell
# 覆盖 9 个场景：配置切换 / 退回重开 / 无已复核 / 无活跃配置 /
# 导入导出 / 多次查询确定性 / include_non_overdue / 与 /explain 交叉验证 / 跨重启一致性
pwsh -ExecutionPolicy Bypass -File .\test-overdue-reconciliation.ps1
```

**预期结果**（测试脚本 SCENARIO 覆盖）：

| 场景 | 预期结果 |
|---|---|
| SC1 配置切换 | `cycle_mismatch.count >= 1`，`snapshot.cycle_days=7`，`active.cycle_days=60`，`applied=7` |
| SC2 退回重开 | `cycle_mismatch` 中 `snapshot.cycle_days=14`（创建时原值），`active.cycle_days=21` |
| SC3 无已复核 | 仪器在 `active_config_fallback` 组；开单未完成时 `fallback_reason_code=ONLY_OPEN_ORDERS`，出现在 `open_orders.details` 中，标注"只展示不参与计算" |
| SC4 无活跃配置 | 仪器在 `unavailable` 组，`unavailable_reason_code=NO_ACTIVE_CONFIG` |
| SC5 导入导出 | `work_order_snapshot` 组中 `snapshot_config_id` / `work_order_id` / `applied_cycle_days` 与导入前一致 |
| SC6 确定性 | 三次同参数查询，`ConvertTo-Json -Compress` 输出完全相同 |
| SC7 参数 | `include_non_overdue=true` 的 `shown_instruments >=` 默认值 |
| SC8 交叉验证 | reconciliation 分组中的 `applied_cycle_days` / `next_due_date` 与 `/explain` 返回一致 |
| SC9 跨重启 | 服务重启后 `summary.*` / `cycle_source_breakdown` / `cycle_mismatch.count` / 分组明细均与重启前完全一致 |

### 审计事件

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/audit` | 列表（`?entity_type=work_order&entity_id=xxx&limit=20&offset=0`） |
| GET | `/api/audit/entity/:entityType/:entityId` | 按实体查历史 |

### 数据导入导出

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/data/export` | 全量 JSON 导出 |
| POST | `/api/data/import` | 全量 JSON 导入（含负数周期等校验） |

**导入校验**：负数 `cycle_days` 拦截，返回 `IMPORT_VALIDATION_FAILED` 并附带详细错误列表。

## 工单状态流转

```
created ──assign──> assigned ──complete──> completed ──verify──> verified
                       │                      │
                       └──── (取消) ──>        └──return──> returned ──reassign──> assigned
```

- **未指派直接完成**：拒绝，错误码 `NOT_ASSIGNED`
- **同一仪器重复开单**：拒绝，错误码 `DUPLICATE_OPEN_ORDER`
- **技师无排班**：拒绝，错误码 `SCHEDULE_CONFLICT`
- **技师工单时间冲突**：拒绝，错误码 `WORK_ORDER_CONFLICT`
- **导入负数周期**：拒绝，错误码 `IMPORT_VALIDATION_FAILED`

## PowerShell 验证脚本

项目包含多套测试脚本，均使用随机 ID/序列号隔离数据，**可重复执行，无需手动清空数据库**：

| 脚本 | 覆盖范围 | 可重复执行 |
|---|---|---|
| `test-acceptance.ps1` | 31 个基础验收场景（CRUD + 状态机 + 冲突检测 + 导出导入） | 是 |
| `test-overdue-regression.ps1` | 逾期计算回归：快照周期 vs 活跃配置、导出导入、确定性、失败场景回归 | 是（每次运行用随机 `runId` 生成唯一序列号，避免撞库） |
| `test-overdue-explain.ps1` | 逾期规则追溯完整链路：配置切换、退回重开、打开工单不混用、活跃配置兜底、导出导入追溯、确定性验证 | 是 |
| `test-overdue-reconciliation.ps1` | **批量对账视图**：配置切换 mismatch 检测、退回重开、无已复核工单 fallback、无活跃配置 unavailable、导出导入分组一致性、include_non_overdue 参数、与 /explain 交叉验证、确定性 | 是 |

```powershell
# 启动服务
npm start

# 另开终端运行测试（可反复执行，不会撞库）
powershell -ExecutionPolicy Bypass -File .\test-overdue-regression.ps1
powershell -ExecutionPolicy Bypass -File .\test-overdue-explain.ps1
pwsh -ExecutionPolicy Bypass -File .\test-overdue-reconciliation.ps1
powershell -ExecutionPolicy Bypass -File .\test-acceptance.ps1
```

### 单条 PowerShell 命令速查

```powershell
# 健康检查
Invoke-RestMethod -Uri http://localhost:3000/health

# 新增仪器
$body = @{ name = "Pressure Gauge"; serial_number = "SN-001" } | ConvertTo-Json
Invoke-RestMethod -Uri http://localhost:3000/api/instruments -Method Post -Body $body -ContentType "application/json"

# 新增配置
$body = @{ instrument_id = "INST_ID"; cycle_days = 90 } | ConvertTo-Json
Invoke-RestMethod -Uri http://localhost:3000/api/configs -Method Post -Body $body -ContentType "application/json"

# 新增技师
$body = @{ name = "Wang Gong"; employee_id = "EMP-001" } | ConvertTo-Json
Invoke-RestMethod -Uri http://localhost:3000/api/technicians -Method Post -Body $body -ContentType "application/json"

# 添加技师排班
$body = @{ start_time = "2026-07-01T09:00:00"; end_time = "2026-07-01T17:00:00" } | ConvertTo-Json
Invoke-RestMethod -Uri http://localhost:3000/api/technicians/TECH_ID/schedules -Method Post -Body $body -ContentType "application/json"

# 创建工单
$body = @{ instrument_id = "INST_ID" } | ConvertTo-Json
Invoke-RestMethod -Uri http://localhost:3000/api/work-orders -Method Post -Body $body -ContentType "application/json"

# 指派工单
$body = @{ technician_id = "TECH_ID"; scheduled_start = "2026-07-01T10:00:00"; scheduled_end = "2026-07-01T12:00:00" } | ConvertTo-Json
Invoke-RestMethod -Uri http://localhost:3000/api/work-orders/WO_ID/assign -Method Post -Body $body -ContentType "application/json"

# 完成工单
$body = @{ result = "Qualified"; certificate_no = "CERT-001" } | ConvertTo-Json
Invoke-RestMethod -Uri http://localhost:3000/api/work-orders/WO_ID/complete -Method Post -Body $body -ContentType "application/json"

# 复核工单
$body = @{ verified_by = "Director Li" } | ConvertTo-Json
Invoke-RestMethod -Uri http://localhost:3000/api/work-orders/WO_ID/verify -Method Post -Body $body -ContentType "application/json"

# 查询逾期
Invoke-RestMethod -Uri http://localhost:3000/api/overdue

# 查询逾期规则追溯（完整解释）
Invoke-RestMethod -Uri "http://localhost:3000/api/overdue/explain?as_of=2026-08-01"

# 查询单仪器逾期追溯
Invoke-RestMethod -Uri "http://localhost:3000/api/overdue/explain/INST_ID?as_of=2026-08-01"

# 导出
Invoke-RestMethod -Uri http://localhost:3000/api/data/export

# 导入
$importData = Get-Content backup.json -Raw
Invoke-RestMethod -Uri http://localhost:3000/api/data/import -Method Post -Body $importData -ContentType "application/json"
```

### curl 验证脚本 (bash)

```bash
#!/bin/bash
# verify.sh — bash 验收脚本
set -e
BASE=http://localhost:3000/api

echo "===== 1. 新增仪器 ====="
INST=$(curl -s -X POST "$BASE/instruments" \
  -H 'Content-Type: application/json' \
  -d '{"name":"Pressure Gauge A","model":"PG-100","serial_number":"SN-2026-001","location":"Lab A"}')
echo "$INST"
INST_ID=$(echo "$INST" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['id'])")

echo "===== 2. 新增校准周期配置 ====="
CFG=$(curl -s -X POST "$BASE/configs" \
  -H 'Content-Type: application/json' \
  -d "{\"instrument_id\":\"$INST_ID\",\"cycle_days\":90}")
CFG_ID=$(echo "$CFG" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['id'])")

echo "===== 3. 新增技师 ====="
TECH=$(curl -s -X POST "$BASE/technicians" \
  -H 'Content-Type: application/json' \
  -d '{"name":"Wang Gong","employee_id":"EMP-001"}')
TECH_ID=$(echo "$TECH" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['id'])")

echo "===== 4. 添加技师排班 ====="
curl -s -X POST "$BASE/technicians/$TECH_ID/schedules" \
  -H 'Content-Type: application/json' \
  -d '{"start_time":"2026-07-01T09:00:00","end_time":"2026-07-01T17:00:00","shift_type":"regular"}' | python3 -m json.tool

echo "===== 5. 创建工单 ====="
WO=$(curl -s -X POST "$BASE/work-orders" \
  -H 'Content-Type: application/json' \
  -d "{\"instrument_id\":\"$INST_ID\",\"planned_date\":\"2026-07-01\"}")
WO_ID=$(echo "$WO" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['id'])")

echo "===== 6. 指派技师 ====="
curl -s -X POST "$BASE/work-orders/$WO_ID/assign" \
  -H 'Content-Type: application/json' \
  -d "{\"technician_id\":\"$TECH_ID\",\"scheduled_start\":\"2026-07-01T10:00:00\",\"scheduled_end\":\"2026-07-01T12:00:00\"}" | python3 -m json.tool

echo "===== 7. 完成工单 ====="
curl -s -X POST "$BASE/work-orders/$WO_ID/complete" \
  -H 'Content-Type: application/json' \
  -d '{"result":"Qualified","deviation":"+0.2%","certificate_no":"CERT-2026-001"}' | python3 -m json.tool

echo "===== 8. 复核通过 ====="
curl -s -X POST "$BASE/work-orders/$WO_ID/verify" \
  -H 'Content-Type: application/json' \
  -d '{"verified_by":"Director Li"}' | python3 -m json.tool

echo "===== 9. 查询逾期清单 ====="
curl -s "$BASE/overdue" | python3 -m json.tool

echo "===== 9b. 查询批量对账视图 ====="
curl -s "$BASE/overdue/reconciliation?as_of=2026-08-01&include_non_overdue=true" | python3 -m json.tool

echo "===== 10. 查询审计事件 ====="
curl -s "$BASE/audit?entity_type=work_order&limit=5" | python3 -m json.tool

echo "===== 11. JSON 导出 ====="
curl -s "$BASE/data/export" > /tmp/calibration_export.json
echo "导出完成"

echo "===== 失败场景验证 ====="

echo "--- 场景A: 未指派直接完成 ---"
WO2=$(curl -s -X POST "$BASE/work-orders" \
  -H 'Content-Type: application/json' \
  -d "{\"instrument_id\":\"$INST_ID\",\"planned_date\":\"2026-09-15\"}")
WO2_ID=$(echo "$WO2" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['id'])")
curl -s -X POST "$BASE/work-orders/$WO2_ID/complete" \
  -H 'Content-Type: application/json' \
  -d '{"result":"Qualified"}' | python3 -m json.tool
echo "(预期: 400 NOT_ASSIGNED)"

echo "--- 场景B: 同一仪器重复打开工单 ---"
curl -s -X POST "$BASE/work-orders" \
  -H 'Content-Type: application/json' \
  -d "{\"instrument_id\":\"$INST_ID\"}" | python3 -m json.tool
echo "(预期: 409 DUPLICATE_OPEN_ORDER)"

echo "--- 场景C: 技师时间冲突(无排班) ---"
INST2=$(curl -s -X POST "$BASE/instruments" \
  -H 'Content-Type: application/json' \
  -d '{"name":"Oscilloscope","serial_number":"SN-OSC-001"}')
INST2_ID=$(echo "$INST2" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['id'])")
curl -s -X POST "$BASE/configs" -H 'Content-Type: application/json' \
  -d "{\"instrument_id\":\"$INST2_ID\",\"cycle_days\":60}" > /dev/null
WO3=$(curl -s -X POST "$BASE/work-orders" -H 'Content-Type: application/json' \
  -d "{\"instrument_id\":\"$INST2_ID\"}")
WO3_ID=$(echo "$WO3" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['id'])")
curl -s -X POST "$BASE/work-orders/$WO3_ID/assign" \
  -H 'Content-Type: application/json' \
  -d "{\"technician_id\":\"$TECH_ID\",\"scheduled_start\":\"2026-08-01T09:00:00\",\"scheduled_end\":\"2026-08-01T11:00:00\"}" | python3 -m json.tool
echo "(预期: 409 SCHEDULE_CONFLICT - 技师该日无排班)"

echo "--- 场景D: 导入负数周期 ---"
curl -s -X POST "$BASE/data/import" \
  -H 'Content-Type: application/json' \
  -d '{
    "instruments":[{"id":"t1","name":"Test","serial_number":"IMP-001"}],
    "calibration_configs":[{"id":"c1","instrument_id":"t1","cycle_days":-10,"version":1}]
  }' | python3 -m json.tool
echo "(预期: 400 IMPORT_VALIDATION_FAILED)"

echo "===== 全部验证完成 ====="
```

## 错误响应格式

所有错误返回统一 JSON 结构，便于定位：

```json
{
  "error": {
    "code": "DUPLICATE_OPEN_ORDER",
    "message": "Instrument Pressure Gauge A (SN-2026-001) already has an open work order: id=xxx, status=assigned. Cannot create a new one until it is verified or returned.",
    "details": { "existingOrderId": "xxx", "existingStatus": "assigned" },
    "path": "/api/work-orders",
    "method": "POST",
    "timestamp": "2026-06-12T10:00:00.000Z"
  }
}
```

| 错误码 | HTTP 状态码 | 含义 |
|---|---|---|
| `VALIDATION_ERROR` | 400 | 请求参数缺失或格式错误 |
| `INVALID_CYCLE_DAYS` | 400 | 校准周期必须为正整数 |
| `INVALID_STATUS_TRANSITION` | 400 | 非法状态流转 |
| `INVALID_DATETIME` | 400 | datetime 格式无效 |
| `INVALID_TIME_RANGE` | 400 | 时间范围无效（start >= end） |
| `NOT_ASSIGNED` | 400 | 工单未指派即尝试完成 |
| `NO_ACTIVE_CONFIG` | 400 | 仪器无活跃配置 |
| `INSTRUMENT_NOT_ACTIVE` | 400 | 仪器不在活跃状态 |
| `TECHNICIAN_NOT_ACTIVE` | 400 | 技师不在活跃状态 |
| `DUPLICATE_OPEN_ORDER` | 409 | 同一仪器已有未完成工单 |
| `DUPLICATE_SERIAL` | 409 | 仪器序列号重复 |
| `DUPLICATE_EMPLOYEE_ID` | 409 | 技师工号重复 |
| `SCHEDULE_CONFLICT` | 409 | 排班时间段重叠或技师无排班 |
| `WORK_ORDER_CONFLICT` | 409 | 技师工单时间冲突 |
| `HAS_OPEN_ORDERS` | 409 | 有未完成工单无法删除 |
| `HAS_ASSIGNED_ORDERS` | 409 | 技师有分配工单无法删除 |
| `IMPORT_VALIDATION_FAILED` | 400 | 导入数据校验失败 |
| `NOT_FOUND` | 404 | 资源不存在 |
| `INTERNAL_ERROR` | 500 | 服务内部错误 |
