# Lab Calibration Scheduler — 实验室仪器校准排期服务

基于 Node.js + Express + SQLite (sql.js) 的本地 REST API 服务，管理仪器台账、校准周期配置、技师排班和校准工单。

## 功能概述

| 模块 | API 前缀 | 核心能力 |
|---|---|---|
| 仪器台账 | `/api/instruments` | CRUD、序列号唯一性校验 |
| 校准周期配置 | `/api/configs` | 版本化配置，历史留痕，修改只影响后续工单 |
| 技师排班 | `/api/technicians` | 技师管理 + datetime 排班，冲突检测 |
| 校准工单 | `/api/work-orders` | 创建→指派→完成→复核 / 退回重开，状态机严格校验 |
| 逾期清单 | `/api/overdue` | 基于配置周期计算逾期，结果重启后可复现 |
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

> 计算逻辑：对每个活跃仪器，取最近 verified 工单的 verified_date + cycle_days_snapshot，若超过基准日期则标记逾期。

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

项目包含完整验收脚本 `test-acceptance.ps1`，覆盖 31 个测试场景：

```powershell
# 启动服务
npm start

# 另开终端运行测试
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
