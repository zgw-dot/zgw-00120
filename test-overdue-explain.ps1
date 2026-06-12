$base = "http://localhost:3000/api"
$pass = 0
$fail = 0

$runId = Get-Random -Minimum 10000 -Maximum 99999
Write-Host "  run_id=$runId (isolation suffix for reproducible runs)"

function Assert-True($name, $condition, $detail = "") {
    if ($condition) {
        Write-Host "  PASS: $name" -ForegroundColor Green
        $script:pass++
    } else {
        Write-Host "  FAIL: $name $detail" -ForegroundColor Red
        $script:fail++
    }
}

function Assert-Eq($name, $actual, $expected) {
    if ($actual -eq $expected) {
        Write-Host "  PASS: $name" -ForegroundColor Green
        $script:pass++
    } else {
        Write-Host "  FAIL: $name (expected=$expected, actual=$actual)" -ForegroundColor Red
        $script:fail++
    }
}

function Assert-NotNull($name, $value) {
    if ($null -ne $value) {
        Write-Host "  PASS: $name" -ForegroundColor Green
        $script:pass++
    } else {
        Write-Host "  FAIL: $name - value is null" -ForegroundColor Red
        $script:fail++
    }
}

function Assert-Null($name, $value) {
    if ($null -eq $value) {
        Write-Host "  PASS: $name" -ForegroundColor Green
        $script:pass++
    } else {
        Write-Host "  FAIL: $name - expected null, got $value" -ForegroundColor Red
        $script:fail++
    }
}

function Try-Fail($name, $expectedCode, $sb) {
    try {
        & $sb
        Write-Host "  FAIL: $name - expected error but got success" -ForegroundColor Red
        $script:fail++
    } catch {
        $errJson = $_.ErrorDetails.Message
        if ($errJson) {
            $resp = $errJson | ConvertFrom-Json
            if ($resp.error.code -eq $expectedCode) {
                Write-Host "  PASS: $name -> $expectedCode" -ForegroundColor Green
                $script:pass++
            } else {
                Write-Host "  FAIL: $name -> expected $expectedCode, got $($resp.error.code)" -ForegroundColor Red
                $script:fail++
            }
        } else {
            Write-Host "  FAIL: $name -> no error details: $($_.Exception.Message)" -ForegroundColor Red
            $script:fail++
        }
    }
}

function Find-InList($list, $instrumentId) {
    foreach ($item in $list) {
        if ($item.instrument_id -eq $instrumentId) { return $item }
    }
    return $null
}

Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host " OVERDUE EXPLAIN - FULL CHAIN TRACEABILITY TEST" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan

# ===================================================================
# SCENARIO 1: Basic chain - Create instrument/config/work order/verify -> query explain
# ===================================================================
Write-Host ""
Write-Host "--- SCENARIO 1: Basic chain + complete explain field check ---" -ForegroundColor Yellow

$inst1Body = @{ name = "Explain Test Gauge"; serial_number = "SN-EXPLAIN-$runId" } | ConvertTo-Json
$inst1 = (Invoke-RestMethod -Uri "$base/instruments" -Method Post -Body $inst1Body -ContentType "application/json").data
$inst1Id = $inst1.id
Write-Host "  instrument: $inst1Id"

$cfg1Body = @{ instrument_id = $inst1Id; cycle_days = 7 } | ConvertTo-Json
$cfg1 = (Invoke-RestMethod -Uri "$base/configs" -Method Post -Body $cfg1Body -ContentType "application/json").data
Assert-Eq "config v1 cycle=7" $cfg1.cycle_days 7

$tech1Body = @{ name = "Explain Tech"; employee_id = "EMP-EXPLAIN-$runId" } | ConvertTo-Json
$tech1 = (Invoke-RestMethod -Uri "$base/technicians" -Method Post -Body $tech1Body -ContentType "application/json").data
$tech1Id = $tech1.id

$today = Get-Date
$schedStart = $today.Date.AddHours(9).ToString("yyyy-MM-ddTHH:mm:ss")
$schedEnd = $today.Date.AddHours(17).ToString("yyyy-MM-ddTHH:mm:ss")
$schedBody = @{ start_time = $schedStart; end_time = $schedEnd } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/technicians/$tech1Id/schedules" -Method Post -Body $schedBody -ContentType "application/json" | Out-Null

$wo1Body = @{ instrument_id = $inst1Id; created_by = "test-runner" } | ConvertTo-Json
$wo1 = (Invoke-RestMethod -Uri "$base/work-orders" -Method Post -Body $wo1Body -ContentType "application/json").data
$wo1Id = $wo1.id
Write-Host "  work order: $wo1Id"

$as1Body = @{
    technician_id = $tech1Id
    scheduled_start = $today.Date.AddHours(10).ToString("yyyy-MM-ddTHH:mm:ss")
    scheduled_end = $today.Date.AddHours(12).ToString("yyyy-MM-ddTHH:mm:ss")
} | ConvertTo-Json
Invoke-RestMethod -Uri "$base/work-orders/$wo1Id/assign" -Method Post -Body $as1Body -ContentType "application/json" | Out-Null

$cp1Body = @{ result = "Qualified"; certificate_no = "CERT-EXPLAIN-$runId" } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/work-orders/$wo1Id/complete" -Method Post -Body $cp1Body -ContentType "application/json" | Out-Null

$vr1Body = @{ verified_by = "QA Manager" } | ConvertTo-Json
$wo1Verified = (Invoke-RestMethod -Uri "$base/work-orders/$wo1Id/verify" -Method Post -Body $vr1Body -ContentType "application/json").data
$wo1VerifiedDate = $wo1Verified.verified_date.Split('T')[0]
Write-Host "  verified_date: $wo1VerifiedDate"

$asOfS1 = $today.AddDays(10).ToString("yyyy-MM-dd")
Write-Host "  query explain as_of=$asOfS1 (10 days later, should be 7-day cycle -> 3 days overdue)"

$explain1Url = "$base/overdue/explain?as_of=$asOfS1&instrument_id=$inst1Id"
$explain1 = (Invoke-RestMethod -Uri $explain1Url -Method Get)
$exp1 = $explain1.data[0]
if (-not $exp1) { $exp1 = $explain1.data }

Write-Host "  --- explain JSON (truncated) ---"
$jsonDump = ($explain1 | ConvertTo-Json -Depth 10)
if ($jsonDump.Length -gt 3000) { $jsonDump = $jsonDump.Substring(0, 3000) }
Write-Host $jsonDump

Assert-NotNull "explain result is not null" $exp1
Assert-NotNull "exp1.base_calculation exists" $exp1.base_calculation
Assert-NotNull "exp1.trace exists" $exp1.trace

Assert-Eq "base_calculation.as_of correct" $exp1.base_calculation.as_of $asOfS1
Assert-Eq "base_calculation.is_overdue is true" $exp1.base_calculation.is_overdue $true
Assert-Eq "base_calculation.applied_cycle_days=7 (snapshot)" $exp1.base_calculation.applied_cycle_days 7

$expectedNextDue = ([datetime]$wo1VerifiedDate).AddDays(7).ToString("yyyy-MM-dd")
Assert-Eq "base_calculation.next_due_date = verified+7d" $exp1.base_calculation.next_due_date $expectedNextDue
Assert-Eq "base_calculation.last_calibrated_date = verified_date" $exp1.base_calculation.last_calibrated_date $wo1VerifiedDate

Assert-Eq "trace.cycle_source = work_order_snapshot" $exp1.trace.cycle_source "work_order_snapshot"
Assert-True "trace.cycle_source_readable is non-empty" ($exp1.trace.cycle_source_readable.Length -gt 5)
Assert-NotNull "trace.work_order exists" $exp1.trace.work_order
Assert-Eq "work_order.id = wo1Id" $exp1.trace.work_order.id $wo1Id
Assert-Eq "work_order.status = verified" $exp1.trace.work_order.status "verified"
Assert-Eq "work_order.cycle_days_snapshot=7" $exp1.trace.work_order.cycle_days_snapshot 7
Assert-Eq "work_order.config_id_snapshot = cfg1.id" $exp1.trace.work_order.config_id_snapshot $cfg1.id
Assert-Eq "work_order.config_version_snapshot=1" $exp1.trace.work_order.config_version_snapshot 1
Assert-Eq "work_order.verified_by = QA Manager" $exp1.trace.work_order.verified_by "QA Manager"

Assert-NotNull "trace.snapshot_config exists" $exp1.trace.snapshot_config
Assert-Eq "snapshot_config.id = cfg1.id" $exp1.trace.snapshot_config.id $cfg1.id
Assert-Eq "snapshot_config.version = 1" $exp1.trace.snapshot_config.version 1
Assert-Eq "snapshot_config.is_active_now initial true" $exp1.trace.snapshot_config.is_active_now $true

Assert-NotNull "trace.reason exists" $exp1.trace.reason
Assert-Eq "reason.code = USING_LAST_VERIFIED_WORK_ORDER" $exp1.trace.reason.code "USING_LAST_VERIFIED_WORK_ORDER"
Assert-Eq "reason.fallback_used = false" $exp1.trace.reason.fallback_used $false

Assert-NotNull "trace.audit_event_ids exists" $exp1.trace.audit_event_ids
Assert-NotNull "audit_event_ids.work_order_create" $exp1.trace.audit_event_ids.work_order_create
Assert-NotNull "audit_event_ids.work_order_verify" $exp1.trace.audit_event_ids.work_order_verify
Assert-NotNull "audit_event_ids.snapshot_config_create" $exp1.trace.audit_event_ids.snapshot_config_create
Assert-True "audit_event_ids.related_all non-empty array" ($exp1.trace.audit_event_ids.related_all.Count -gt 0)

Assert-NotNull "trace.import_info exists" $exp1.trace.import_info
Assert-Eq "import_info.is_imported = false" $exp1.trace.import_info.is_imported $false
Assert-Eq "import_info.evidence = SYSTEM_CREATED" $exp1.trace.import_info.evidence "SYSTEM_CREATED"

Assert-Null "no open_work_order currently" $exp1.open_work_order

# ===================================================================
# SCENARIO 2: Config version switching - snapshot not affected by new config
# ===================================================================
Write-Host ""
Write-Host "--- SCENARIO 2: Config version switching - snapshot vs active ---" -ForegroundColor Yellow

$cfg2Body = @{ instrument_id = $inst1Id; cycle_days = 60 } | ConvertTo-Json
$cfg2 = (Invoke-RestMethod -Uri "$base/configs" -Method Post -Body $cfg2Body -ContentType "application/json").data
Assert-Eq "config v2 cycle=60" $cfg2.cycle_days 60
Assert-Eq "config v2 version=2" $cfg2.version 2

$explain2Url = "$base/overdue/explain/$inst1Id`?as_of=$asOfS1"
$explain2 = (Invoke-RestMethod -Uri $explain2Url -Method Get)
$exp2 = $explain2.data

Write-Host "  active_config_now.version=$($exp2.trace.active_config_now.version)"
Write-Host "  snapshot_config.is_active_now=$($exp2.trace.snapshot_config.is_active_now)"

Assert-Eq "applied_cycle_days still 7 (snapshot)" $exp2.base_calculation.applied_cycle_days 7
Assert-Eq "next_due_date unchanged" $exp2.base_calculation.next_due_date $expectedNextDue
Assert-Eq "snapshot_config.is_active_now becomes false" $exp2.trace.snapshot_config.is_active_now $false
Assert-NotNull "active_config_now exists" $exp2.trace.active_config_now
Assert-Eq "active_config_now.version=2" $exp2.trace.active_config_now.version 2
Assert-Eq "active_config_now.cycle_days=60" $exp2.trace.active_config_now.cycle_days 60

# ===================================================================
# SCENARIO 3: Open work order coexists with historical verify - no mixing
# ===================================================================
Write-Host ""
Write-Host "--- SCENARIO 3: Open work order + historical verify - no mixing ---" -ForegroundColor Yellow

$wo2Body = @{ instrument_id = $inst1Id } | ConvertTo-Json
$wo2 = (Invoke-RestMethod -Uri "$base/work-orders" -Method Post -Body $wo2Body -ContentType "application/json").data
$wo2Id = $wo2.id
Write-Host "  opened new (unverified) work order: $wo2Id (status=$($wo2.status))"

$explain3Url = "$base/overdue/explain/$inst1Id`?as_of=$asOfS1"
$explain3 = (Invoke-RestMethod -Uri $explain3Url -Method Get)
$exp3 = $explain3.data

Assert-Eq "cycle_source still snapshot (not disturbed by open WO)" $exp3.trace.cycle_source "work_order_snapshot"
Assert-Eq "work_order.id still verified wo1" $exp3.trace.work_order.id $wo1Id
Assert-NotNull "open_work_order exists" $exp3.open_work_order
Assert-Eq "open_work_order.id = wo2Id" $exp3.open_work_order.id $wo2Id
Assert-Eq "open_work_order.status = created" $exp3.open_work_order.status "created"

# ===================================================================
# SCENARIO 4: No verified history -> active config fallback with readable reason
# ===================================================================
Write-Host ""
Write-Host "--- SCENARIO 4: No verified history -> active config fallback ---" -ForegroundColor Yellow

$inst4Body = @{ name = "No Verify Instrument"; serial_number = "SN-NOVERIFY-$runId" } | ConvertTo-Json
$inst4 = (Invoke-RestMethod -Uri "$base/instruments" -Method Post -Body $inst4Body -ContentType "application/json").data
$inst4Id = $inst4.id
$inst4CreatedDate = $inst4.created_at.Split('T')[0]
Write-Host "  instrument created: $inst4CreatedDate"

$cfg4Body = @{ instrument_id = $inst4Id; cycle_days = 3 } | ConvertTo-Json
$cfg4 = (Invoke-RestMethod -Uri "$base/configs" -Method Post -Body $cfg4Body -ContentType "application/json").data

$asOfS4 = $today.AddDays(5).ToString("yyyy-MM-dd")
$explain4Url = "$base/overdue/explain/$inst4Id`?as_of=$asOfS4"
$explain4 = (Invoke-RestMethod -Uri $explain4Url -Method Get)
$exp4 = $explain4.data

Write-Host "  cycle_source=$($exp4.trace.cycle_source), reason.code=$($exp4.trace.reason.code)"
Write-Host "  reason.message=$($exp4.trace.reason.message)"

Assert-Eq "cycle_source = active_config_fallback" $exp4.trace.cycle_source "active_config_fallback"
Assert-Eq "reason.code = NO_WORK_ORDERS_AT_ALL" $exp4.trace.reason.code "NO_WORK_ORDERS_AT_ALL"
Assert-Eq "reason.fallback_used = true" $exp4.trace.reason.fallback_used $true

$expectedNextDue4 = ([datetime]$inst4CreatedDate).AddDays(3).ToString("yyyy-MM-dd")
Assert-Eq "next_due_date = created+3d" $exp4.base_calculation.next_due_date $expectedNextDue4
Assert-Eq "applied_cycle_days=3 (active config)" $exp4.base_calculation.applied_cycle_days 3
Assert-Eq "active_config_now.id = cfg4.id" $exp4.trace.active_config_now.id $cfg4.id
Assert-NotNull "audit_event_ids.active_config_create" $exp4.trace.audit_event_ids.active_config_create
Assert-NotNull "audit_event_ids.instrument_create" $exp4.trace.audit_event_ids.instrument_create

# Sub-case: create order but don't verify -> ONLY_OPEN_ORDERS reason
Write-Host "  Sub-case: create order but don't verify -> ONLY_OPEN_ORDERS..."
$wo4Body = @{ instrument_id = $inst4Id } | ConvertTo-Json
$wo4 = (Invoke-RestMethod -Uri "$base/work-orders" -Method Post -Body $wo4Body -ContentType "application/json").data

$explain4b = (Invoke-RestMethod -Uri $explain4Url -Method Get)
$exp4b = $explain4b.data
Assert-Eq "reason becomes ONLY_OPEN_ORDERS" $exp4b.trace.reason.code "ONLY_OPEN_ORDERS"
Assert-NotNull "open_work_order exists" $exp4b.open_work_order

# ===================================================================
# SCENARIO 5: Export -> Import - traceability still matches original IDs
# ===================================================================
Write-Host ""
Write-Host "--- SCENARIO 5: Export -> Import round-trip - traceability preserved ---" -ForegroundColor Yellow

$beforeExpUrl = "$base/overdue/explain/$inst1Id`?as_of=$asOfS1"
$beforeExp = (Invoke-RestMethod -Uri $beforeExpUrl -Method Get).data
$beforeSnapshotWoId = $beforeExp.trace.work_order.id
$beforeSnapshotCfgId = $beforeExp.trace.work_order.config_id_snapshot
$beforeCycleDays = $beforeExp.base_calculation.applied_cycle_days
$beforeNextDue = $beforeExp.base_calculation.next_due_date

Write-Host "  Pre-export: wo=$beforeSnapshotWoId, cfg=$beforeSnapshotCfgId, cycle=$beforeCycleDays, next_due=$beforeNextDue"

# Export
$export = (Invoke-RestMethod -Uri "$base/data/export" -Method Get).data
$exportInstMatches = @($export.instruments | Where-Object { $_.serial_number -eq "SN-EXPLAIN-$runId" })
Assert-True "export contains instrument SN-EXPLAIN-001" ($exportInstMatches.Count -gt 0)
$exportedWo = $export.work_orders | Where-Object { $_.id -eq $wo1Id }
Assert-NotNull "export contains verified work order wo1Id" $exportedWo
Assert-Eq "exported wo cycle_days_snapshot preserved" $exportedWo.cycle_days_snapshot 7

# Simulate clean import into new DB using brand-new unique IDs
$rand = Get-Random -Minimum 1000 -Maximum 9999
$newSerial = "SN-IMPORT-TRACE-$rand"
$newInstId = "inst-import-trace-$rand"
$newCfgId = "cfg-import-trace-$rand"
$newWoId = "wo-import-trace-$rand"
$newTechId = "tech-import-$rand"
$newEmpId = "EMP-IMP-$rand"

$importData = @{
    instruments = @(
        @{
            id = $newInstId
            name = "Imported Trace Instrument"
            serial_number = $newSerial
            model = "IT-100"
            status = "active"
            created_at = "2026-01-15T09:00:00.000Z"
            updated_at = "2026-01-15T09:00:00.000Z"
        }
    )
    calibration_configs = @(
        @{
            id = $newCfgId
            instrument_id = $newInstId
            cycle_days = 5
            version = 1
            is_active = 1
            effective_from = "2026-01-15T10:00:00.000Z"
            created_at = "2026-01-15T10:00:00.000Z"
        }
    )
    technicians = @(
        @{
            id = $newTechId
            name = "Imported Tech"
            employee_id = $newEmpId
            status = "active"
            created_at = "2026-01-10T00:00:00.000Z"
            updated_at = "2026-01-10T00:00:00.000Z"
        }
    )
    technician_schedules = @()
    work_orders = @(
        @{
            id = $newWoId
            instrument_id = $newInstId
            config_id = $newCfgId
            config_version = 1
            cycle_days_snapshot = 5
            technician_id = $newTechId
            status = "verified"
            completed_date = "2026-02-01T14:00:00.000Z"
            verified_date = "2026-02-02T10:00:00.000Z"
            result = "Pass"
            certificate_no = "CERT-IMP-001"
            created_by = "imported-user"
            verified_by = "imported-qa"
            created_at = "2026-01-20T08:00:00.000Z"
            updated_at = "2026-02-02T10:00:00.000Z"
        }
    )
    audit_events = @(
        @{
            event_type = "CREATE"
            entity_type = "instrument"
            entity_id = $newInstId
            new_values = @{ id = $newInstId; name = "Imported Trace Instrument" }
            old_values = $null
            operator = "legacy-system"
            timestamp = "2026-01-15T09:00:00.000Z"
        }
        @{
            event_type = "CREATE"
            entity_type = "work_order"
            entity_id = $newWoId
            new_values = @{ id = $newWoId; cycle_days_snapshot = 5 }
            old_values = $null
            operator = "legacy-user"
            timestamp = "2026-01-20T08:00:00.000Z"
        }
        @{
            event_type = "STATUS_CHANGE"
            entity_type = "work_order"
            entity_id = $newWoId
            new_values = @{ status = "verified" }
            old_values = @{ status = "completed" }
            operator = "legacy-qa"
            timestamp = "2026-02-02T10:00:00.000Z"
        }
    )
} | ConvertTo-Json -Depth 10

$importResult = (Invoke-RestMethod -Uri "$base/data/import" -Method Post -Body $importData -ContentType "application/json").data
Write-Host "  Import result: instruments=$($importResult.instruments.created), configs=$($importResult.calibration_configs.created), work_orders=$($importResult.work_orders.created), entity_import_audits=$($importResult.entity_import_audits.created)"

Assert-True "import created >=1 instrument" ($importResult.instruments.created -ge 1)
Assert-True "import created >=1 work_order" ($importResult.work_orders.created -ge 1)
Assert-True "ENTITY_IMPORT audit events generated" ($importResult.entity_import_audits.created -gt 0)

# Post-import explain for new instrument
$asOfS5 = "2026-03-01"
$explain5Url = "$base/overdue/explain/$newInstId`?as_of=$asOfS5"
$explain5 = (Invoke-RestMethod -Uri $explain5Url -Method Get)
$exp5 = $explain5.data

Write-Host "  Post-import explain:"
Write-Host "    cycle_source=$($exp5.trace.cycle_source)"
Write-Host "    work_order.id=$($exp5.trace.work_order.id) (expect: $newWoId)"
Write-Host "    work_order.config_id_snapshot=$($exp5.trace.work_order.config_id_snapshot) (expect: $newCfgId)"
Write-Host "    applied_cycle_days=$($exp5.base_calculation.applied_cycle_days)"
Write-Host "    next_due_date=$($exp5.base_calculation.next_due_date)"
Write-Host "    import_info.is_imported=$($exp5.trace.import_info.is_imported)"
Write-Host "    import_info.evidence=$($exp5.trace.import_info.evidence)"

Assert-Eq "post-import work_order.id matches" $exp5.trace.work_order.id $newWoId
Assert-Eq "post-import config_id_snapshot matches" $exp5.trace.work_order.config_id_snapshot $newCfgId
Assert-Eq "post-import config_version_snapshot=1" $exp5.trace.work_order.config_version_snapshot 1
Assert-Eq "post-import cycle_days=5 (snapshot)" $exp5.base_calculation.applied_cycle_days 5
$expectedNextDue5 = "2026-02-07"
Assert-Eq "post-import next_due_date = 2026-02-02 + 5d" $exp5.base_calculation.next_due_date $expectedNextDue5
Assert-Eq "import_info.is_imported = true" $exp5.trace.import_info.is_imported $true
Assert-Eq "import_info.evidence = ENTITY_IMPORT_AUDIT" $exp5.trace.import_info.evidence "ENTITY_IMPORT_AUDIT"
Assert-NotNull "import_info.related_audit_id exists" $exp5.trace.import_info.related_audit_id

# ===================================================================
# SCENARIO 6: Determinism - same query repeated yields identical results
# ===================================================================
Write-Host ""
Write-Host "--- SCENARIO 6: Determinism - repeated queries identical ---" -ForegroundColor Yellow

$q1 = (Invoke-RestMethod -Uri $beforeExpUrl -Method Get).data
$q2 = (Invoke-RestMethod -Uri $beforeExpUrl -Method Get).data
$q3 = (Invoke-RestMethod -Uri $beforeExpUrl -Method Get).data

$q1Json = $q1 | ConvertTo-Json -Depth 10 -Compress
$q2Json = $q2 | ConvertTo-Json -Depth 10 -Compress
$q3Json = $q3 | ConvertTo-Json -Depth 10 -Compress

Assert-Eq "q1 == q2 (repeated query identical)" $q1Json $q2Json
Assert-Eq "q2 == q3 (multi-query identical)" $q2Json $q3Json

# Cross-verify explain vs original compact /api/overdue
$compact = (Invoke-RestMethod -Uri "$base/overdue?as_of=$asOfS1" -Method Get).data
$compactInst1 = Find-InList $compact $inst1Id

Assert-NotNull "compact endpoint also has inst1" $compactInst1
Assert-Eq "compact.applied_cycle_days == explain" $compactInst1.applied_cycle_days $beforeExp.base_calculation.applied_cycle_days
Assert-Eq "compact.next_due_date == explain" $compactInst1.next_due_date $beforeExp.base_calculation.next_due_date
Assert-Eq "compact.cycle_source == explain" $compactInst1.cycle_source $beforeExp.trace.cycle_source
Assert-Eq "compact.snapshot_config_version == explain" $compactInst1.snapshot_config_version $beforeExp.trace.work_order.config_version_snapshot

# ===================================================================
# SCENARIO 7: Return + reassign workflow + config switch combined
# ===================================================================
Write-Host ""
Write-Host "--- SCENARIO 7: Return-reopen + config switch complex case ---" -ForegroundColor Yellow

$rnd7 = Get-Random -Minimum 1000 -Maximum 9999
$inst7Body = @{ name = "Return Reopen Test"; serial_number = "SN-RETURN-$rnd7" } | ConvertTo-Json
$inst7 = (Invoke-RestMethod -Uri "$base/instruments" -Method Post -Body $inst7Body -ContentType "application/json").data
$inst7Id = $inst7.id

$cfg7v1Body = @{ instrument_id = $inst7Id; cycle_days = 14 } | ConvertTo-Json
$cfg7v1 = (Invoke-RestMethod -Uri "$base/configs" -Method Post -Body $cfg7v1Body -ContentType "application/json").data

$tech7Body = @{ name = "Return Tech"; employee_id = "EMP-RETURN-$rnd7" } | ConvertTo-Json
$tech7 = (Invoke-RestMethod -Uri "$base/technicians" -Method Post -Body $tech7Body -ContentType "application/json").data
$tech7Id = $tech7.id

$sched7Body = @{
    start_time = $today.Date.AddHours(9).ToString("yyyy-MM-ddTHH:mm:ss")
    end_time = $today.Date.AddHours(18).ToString("yyyy-MM-ddTHH:mm:ss")
} | ConvertTo-Json
Invoke-RestMethod -Uri "$base/technicians/$tech7Id/schedules" -Method Post -Body $sched7Body -ContentType "application/json" | Out-Null

$wo7Body = @{ instrument_id = $inst7Id } | ConvertTo-Json
$wo7 = (Invoke-RestMethod -Uri "$base/work-orders" -Method Post -Body $wo7Body -ContentType "application/json").data
$wo7Id = $wo7.id

$as7Body = @{
    technician_id = $tech7Id
    scheduled_start = $today.Date.AddHours(11).ToString("yyyy-MM-ddTHH:mm:ss")
    scheduled_end = $today.Date.AddHours(13).ToString("yyyy-MM-ddTHH:mm:ss")
} | ConvertTo-Json
Invoke-RestMethod -Uri "$base/work-orders/$wo7Id/assign" -Method Post -Body $as7Body -ContentType "application/json" | Out-Null

$cp7Body = @{ result = "Needs recalibration"; certificate_no = "CERT-RETURN-001" } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/work-orders/$wo7Id/complete" -Method Post -Body $cp7Body -ContentType "application/json" | Out-Null

# Return the work order
$rt7Body = @{ notes = "Returned for rework - deviation detected" } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/work-orders/$wo7Id/return" -Method Post -Body $rt7Body -ContentType "application/json" | Out-Null

# Switch config while work order is in returned state (after return, before re-verify)
$cfg7v2Body = @{ instrument_id = $inst7Id; cycle_days = 21 } | ConvertTo-Json
$cfg7v2 = (Invoke-RestMethod -Uri "$base/configs" -Method Post -Body $cfg7v2Body -ContentType "application/json").data

# Reassign, complete again, re-verify
$ra7Body = @{
    technician_id = $tech7Id
    scheduled_start = $today.Date.AddHours(14).ToString("yyyy-MM-ddTHH:mm:ss")
    scheduled_end = $today.Date.AddHours(16).ToString("yyyy-MM-ddTHH:mm:ss")
} | ConvertTo-Json
Invoke-RestMethod -Uri "$base/work-orders/$wo7Id/reassign" -Method Post -Body $ra7Body -ContentType "application/json" | Out-Null

$cp7bBody = @{ result = "Qualified after rework"; certificate_no = "CERT-RETURN-001-R2" } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/work-orders/$wo7Id/complete" -Method Post -Body $cp7bBody -ContentType "application/json" | Out-Null

$vr7Body = @{ verified_by = "Senior QA" } | ConvertTo-Json
$wo7Final = (Invoke-RestMethod -Uri "$base/work-orders/$wo7Id/verify" -Method Post -Body $vr7Body -ContentType "application/json").data
$wo7FinalDate = $wo7Final.verified_date.Split('T')[0]

# Key: snapshot was 14 at creation; active config now is v2=21; snapshot must win
Write-Host "  work order snapshot cycle_days=$($wo7Final.cycle_days_snapshot) (expect 14, active is now 21)"
Assert-Eq "return-reopen snapshot still v1=14" $wo7Final.cycle_days_snapshot 14

$asOfS7 = $today.AddDays(20).ToString("yyyy-MM-dd")
$explain7Url = "$base/overdue/explain/$inst7Id`?as_of=$asOfS7"
$explain7 = (Invoke-RestMethod -Uri $explain7Url -Method Get)
$exp7 = $explain7.data

Write-Host "  returned_count_before_verify=$($exp7.trace.work_order.returned_count_before_verify)"
Write-Host "  applied_cycle_days=$($exp7.base_calculation.applied_cycle_days)"
Write-Host "  active_config_now.cycle_days=$($exp7.trace.active_config_now.cycle_days)"

Assert-Eq "applied_cycle_days = snapshot 14" $exp7.base_calculation.applied_cycle_days 14
Assert-True "returned_count_before_verify >= 1" ($exp7.trace.work_order.returned_count_before_verify -ge 1)
Assert-Eq "active config now cycle=21" $exp7.trace.active_config_now.cycle_days 21
Assert-Eq "active config version=v2" $exp7.trace.active_config_now.version 2
$expectedNextDue7 = ([datetime]$wo7FinalDate).AddDays(14).ToString("yyyy-MM-dd")
Assert-Eq "next_due_date = verified + 14d (snapshot)" $exp7.base_calculation.next_due_date $expectedNextDue7

# ===================================================================
# SCENARIO 8: Global explain filtering + meta stats
# ===================================================================
Write-Host ""
Write-Host "--- SCENARIO 8: Global explain filtering + meta stats ---" -ForegroundColor Yellow

$allExp = (Invoke-RestMethod -Uri "$base/overdue/explain?as_of=$($today.ToString('yyyy-MM-dd'))" -Method Get)
Assert-NotNull "meta.as_of exists" $allExp.meta.as_of
Assert-NotNull "meta.cycle_source_breakdown exists" $allExp.meta.cycle_source_breakdown
Assert-NotNull "meta.fields_legend exists" $allExp.meta.fields_legend
Write-Host "  shown_count=$($allExp.meta.shown_count), total_instruments=$($allExp.meta.total_instruments)"

$allExpNonOverdue = (Invoke-RestMethod -Uri "$base/overdue/explain?include_non_overdue=true" -Method Get)
Write-Host "  include_non_overdue=true -> shown_count=$($allExpNonOverdue.meta.shown_count)"
Assert-True "include_non_overdue=true shows >= records" ($allExpNonOverdue.meta.shown_count -ge $allExp.meta.shown_count)

# ===================================================================
# REGRESSION: Old scenarios still work
# ===================================================================
Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host " REGRESSION: Verify old failure scenarios intact" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan

# R1: Duplicate open order
Write-Host ""
Write-Host "--- R1: Duplicate open order rejection ---" -ForegroundColor Yellow
$rndR1 = Get-Random
$r1InstBody = @{ name = "R1 Dup Test"; serial_number = "SN-R1-DUP-$rndR1" } | ConvertTo-Json
$r1Inst = (Invoke-RestMethod -Uri "$base/instruments" -Method Post -Body $r1InstBody -ContentType "application/json").data
$r1CfgBody = @{ instrument_id = $r1Inst.id; cycle_days = 10 } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/configs" -Method Post -Body $r1CfgBody -ContentType "application/json" | Out-Null
$r1WoBody = @{ instrument_id = $r1Inst.id } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/work-orders" -Method Post -Body $r1WoBody -ContentType "application/json" | Out-Null
Try-Fail "Duplicate open order" "DUPLICATE_OPEN_ORDER" {
    Invoke-RestMethod -Uri "$base/work-orders" -Method Post -Body $r1WoBody -ContentType "application/json"
}

# R2: Complete without assignment
Write-Host ""
Write-Host "--- R2: Complete without assignment rejection ---" -ForegroundColor Yellow
$rndR2 = Get-Random
$r2InstBody = @{ name = "R2 NoAssign Test"; serial_number = "SN-R2-NOASSIGN-$rndR2" } | ConvertTo-Json
$r2Inst = (Invoke-RestMethod -Uri "$base/instruments" -Method Post -Body $r2InstBody -ContentType "application/json").data
$r2CfgBody = @{ instrument_id = $r2Inst.id; cycle_days = 5 } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/configs" -Method Post -Body $r2CfgBody -ContentType "application/json" | Out-Null
$r2WoBody = @{ instrument_id = $r2Inst.id } | ConvertTo-Json
$r2WoId = (Invoke-RestMethod -Uri "$base/work-orders" -Method Post -Body $r2WoBody -ContentType "application/json").data.id
Try-Fail "Complete without assignment" "NOT_ASSIGNED" {
    $b = @{ result = "Qualified" } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/work-orders/$r2WoId/complete" -Method Post -Body $b -ContentType "application/json"
}

# R3: Negative cycle import
Write-Host ""
Write-Host "--- R3: Negative cycle import rejection ---" -ForegroundColor Yellow
$rndR3 = Get-Random
Try-Fail "Import negative cycle" "IMPORT_VALIDATION_FAILED" {
    $impData = @{
        instruments = @(@{ id = "neg-test-r3-$rndR3"; name = "Neg R3"; serial_number = "NEG-R3-$rndR3" })
        calibration_configs = @(@{ id = "neg-cfg-r3-$rndR3"; instrument_id = "neg-test-r3-$rndR3"; cycle_days = -15; version = 1 })
        technicians = @(); technician_schedules = @(); work_orders = @(); audit_events = @()
    } | ConvertTo-Json -Depth 10
    Invoke-RestMethod -Uri "$base/data/import" -Method Post -Body $impData -ContentType "application/json"
}

# R4: No active config -> explain unavailable with clear reason
Write-Host ""
Write-Host "--- R4: No active config -> explain unavailable ---" -ForegroundColor Yellow
$rndR4 = Get-Random
$r4InstBody = @{ name = "R4 NoConfig"; serial_number = "SN-R4-NOCFG-$rndR4" } | ConvertTo-Json
$r4Inst = (Invoke-RestMethod -Uri "$base/instruments" -Method Post -Body $r4InstBody -ContentType "application/json").data
$r4Url = "$base/overdue/explain/$($r4Inst.id)"
$r4Exp = (Invoke-RestMethod -Uri $r4Url -Method Get).data
Assert-Eq "no config -> cycle_source=unavailable" $r4Exp.trace.cycle_source "unavailable"
Assert-Eq "no config -> reason.code=NO_ACTIVE_CONFIG" $r4Exp.trace.reason.code "NO_ACTIVE_CONFIG"
Assert-Eq "is_overdue=false (cannot compute)" $r4Exp.base_calculation.is_overdue $false

# ===================================================================
# Summary
# ===================================================================
Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host " OVERDUE EXPLAIN FULL CHAIN + REGRESSION SUMMARY: $pass PASS, $fail FAIL" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan

if ($fail -gt 0) { exit 1 }
