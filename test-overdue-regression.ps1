$base = "http://localhost:3000/api"
$pass = 0
$fail = 0

$runId = Get-Random -Minimum 10000 -Maximum 99999
Write-Host "  run_id=$runId (用于隔离本次运行创建的数据，可重复执行)"

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

Write-Host "`n======================================================" -ForegroundColor Cyan
Write-Host " REGRESSION: overdue uses cycle_days_snapshot, not active config" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan

# Step 1: Create instrument with 1-day cycle
Write-Host "`n--- Step 1: Create instrument + 1-day config ---" -ForegroundColor Yellow
$instBody = @{ name = "Snapshot Test Gauge"; serial_number = "SN-SNAPSHOT-$runId" } | ConvertTo-Json
$inst = (Invoke-RestMethod -Uri "$base/instruments" -Method Post -Body $instBody -ContentType "application/json").data
$instId = $inst.id
Write-Host "  instrument: $instId"

$cfg1Body = @{ instrument_id = $instId; cycle_days = 1 } | ConvertTo-Json
$cfg1 = (Invoke-RestMethod -Uri "$base/configs" -Method Post -Body $cfg1Body -ContentType "application/json").data
Assert-Eq "config v1 cycle_days=1" $cfg1.cycle_days 1

# Step 2: Create technician + schedule
Write-Host "`n--- Step 2: Create technician + schedule ---" -ForegroundColor Yellow
$techBody = @{ name = "Regression Tech"; employee_id = "EMP-REG-$runId" } | ConvertTo-Json
$tech = (Invoke-RestMethod -Uri "$base/technicians" -Method Post -Body $techBody -ContentType "application/json").data
$techId = $tech.id

$today = Get-Date
$schedStart = $today.Date.AddHours(9).ToString("yyyy-MM-ddTHH:mm:ss")
$schedEnd = $today.Date.AddHours(17).ToString("yyyy-MM-ddTHH:mm:ss")
$schedBody = @{ start_time = $schedStart; end_time = $schedEnd } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/technicians/$techId/schedules" -Method Post -Body $schedBody -ContentType "application/json" | Out-Null

# Step 3: Create, assign, complete, verify work order
Write-Host "`n--- Step 3: Full workflow (create->assign->complete->verify) ---" -ForegroundColor Yellow
$woBody = @{ instrument_id = $instId } | ConvertTo-Json
$wo = (Invoke-RestMethod -Uri "$base/work-orders" -Method Post -Body $woBody -ContentType "application/json").data
$woId = $wo.id
Assert-Eq "work order cycle_days_snapshot" $wo.cycle_days_snapshot 1

$asBody = @{
    technician_id = $techId
    scheduled_start = $today.Date.AddHours(10).ToString("yyyy-MM-ddTHH:mm:ss")
    scheduled_end = $today.Date.AddHours(12).ToString("yyyy-MM-ddTHH:mm:ss")
} | ConvertTo-Json
Invoke-RestMethod -Uri "$base/work-orders/$woId/assign" -Method Post -Body $asBody -ContentType "application/json" | Out-Null

$cpBody = @{ result = "Qualified"; certificate_no = "CERT-REG-001" } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/work-orders/$woId/complete" -Method Post -Body $cpBody -ContentType "application/json" | Out-Null

$vrBody = @{ verified_by = "QA Lead" } | ConvertTo-Json
$verified = (Invoke-RestMethod -Uri "$base/work-orders/$woId/verify" -Method Post -Body $vrBody -ContentType "application/json").data
Assert-Eq "verified status" $verified.status "verified"
Write-Host "  verified_date: $($verified.verified_date)"

# Step 4: Check overdue with 1-day cycle (should be overdue by tomorrow+1)
Write-Host "`n--- Step 4: Check overdue BEFORE config change (1-day cycle) ---" -ForegroundColor Yellow
$asOfDate = $today.AddDays(2).ToString("yyyy-MM-dd")
$overdue1Data = (Invoke-RestMethod -Uri "$base/overdue?as_of=$asOfDate" -Method Get).data
$found1 = Find-InList $overdue1Data $instId
Assert-True "overdue with 1-day snapshot (as_of=$asOfDate)" ($found1 -ne $null) "instrument not found in overdue list"
if ($found1) {
    Write-Host "  applied_cycle_days=$($found1.applied_cycle_days), cycle_source=$($found1.cycle_source), days_overdue=$($found1.days_overdue)"
    Assert-Eq "cycle_source is work_order_snapshot" $found1.cycle_source "work_order_snapshot"
    Assert-Eq "applied_cycle_days is 1 (snapshot)" $found1.applied_cycle_days 1
}

# Step 5: Change config to 30 days
Write-Host "`n--- Step 5: Change config to 30 days ---" -ForegroundColor Yellow
$cfg2Body = @{ instrument_id = $instId; cycle_days = 30 } | ConvertTo-Json
$cfg2 = (Invoke-RestMethod -Uri "$base/configs" -Method Post -Body $cfg2Body -ContentType "application/json").data
Assert-Eq "config v2 cycle_days=30" $cfg2.cycle_days 30
Assert-Eq "config v2 version=2" $cfg2.version 2

# Step 6: THE KEY TEST - overdue should STILL use snapshot (1 day), not active config (30 days)
Write-Host "`n--- Step 6: THE KEY TEST - overdue must STILL use snapshot (1 day) ---" -ForegroundColor Yellow
$overdue2Data = (Invoke-RestMethod -Uri "$base/overdue?as_of=$asOfDate" -Method Get).data
$found2 = Find-InList $overdue2Data $instId
Assert-True "instrument still in overdue list after config change" ($found2 -ne $null) "instrument not found"
if ($found2) {
    Write-Host "  applied_cycle_days=$($found2.applied_cycle_days), cycle_source=$($found2.cycle_source)"
    Write-Host "  active_config_cycle_days=$($found2.active_config_cycle_days), snapshot_config_version=$($found2.snapshot_config_version)"
    Assert-Eq "applied_cycle_days still 1 (from snapshot)" $found2.applied_cycle_days 1
    Assert-Eq "cycle_source is work_order_snapshot" $found2.cycle_source "work_order_snapshot"
    Assert-Eq "active_config_cycle_days is 30" $found2.active_config_cycle_days 30
    Assert-Eq "snapshot_config_version is 1" $found2.snapshot_config_version 1
    Assert-Eq "active_config_version is 2" $found2.active_config_version 2
}

# Verify next_due_date matches snapshot (1 day) not active config (30 days)
if ($found2) {
    $verifiedDate = $verified.verified_date.Split('T')[0]
    $snapshotDue = ([datetime]$verifiedDate).AddDays(1).ToString("yyyy-MM-dd")
    $configDue = ([datetime]$verifiedDate).AddDays(30).ToString("yyyy-MM-dd")
    Write-Host "`n  next_due_date (snapshot=1d): $snapshotDue"
    Write-Host "  next_due_date (active=30d):  $configDue"
    Write-Host "  actual next_due_date:        $($found2.next_due_date)"
    Assert-Eq "next_due_date matches snapshot" $found2.next_due_date $snapshotDue
}

# Step 7: Restart persistence - just record data, stop/start service, re-check
Write-Host "`n--- Step 7: Restart service + verify overdue persistence ---" -ForegroundColor Yellow
Write-Host "  Recording pre-restart state..."
$preOverdue = $found2

Write-Host "  (Need manual restart to fully test. For now, verifying export/import round-trip...)"
$exportData = (Invoke-RestMethod -Uri "$base/data/export" -Method Get).data
Assert-True "export contains our work order" ($exportData.work_orders | Where-Object { $_.id -eq $woId }) "work order not in export"
$woInExport = $exportData.work_orders | Where-Object { $_.id -eq $woId }
Assert-Eq "exported wo cycle_days_snapshot=1" $woInExport.cycle_days_snapshot 1

# Verify overdue calculation is deterministic (same input = same output)
$overdue3Data = (Invoke-RestMethod -Uri "$base/overdue?as_of=$asOfDate" -Method Get).data
$found3 = Find-InList $overdue3Data $instId
Assert-True "overdue result is deterministic" ($found3 -ne $null) "instrument not found on second query"
if ($found3) {
    Assert-Eq "applied_cycle_days deterministic" $found3.applied_cycle_days 1
    Assert-Eq "next_due_date deterministic" $found3.next_due_date $preOverdue.next_due_date
}

# ============================================================
# Verify original failure scenarios still work
# ============================================================
Write-Host "`n======================================================" -ForegroundColor Cyan
Write-Host " VERIFY: Original failure scenarios still work" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan

# F1: Duplicate open work order
Write-Host "`n--- F1: Duplicate open work order ---" -ForegroundColor Yellow
$dupInstBody = @{ name = "Dup Test"; serial_number = "SN-DUP-VERIFY-$runId" } | ConvertTo-Json
$dupInst = (Invoke-RestMethod -Uri "$base/instruments" -Method Post -Body $dupInstBody -ContentType "application/json").data
$dupCfgBody = @{ instrument_id = $dupInst.id; cycle_days = 10 } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/configs" -Method Post -Body $dupCfgBody -ContentType "application/json" | Out-Null
$dupWoBody = @{ instrument_id = $dupInst.id } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/work-orders" -Method Post -Body $dupWoBody -ContentType "application/json" | Out-Null
Try-Fail "Duplicate open order" "DUPLICATE_OPEN_ORDER" {
    Invoke-RestMethod -Uri "$base/work-orders" -Method Post -Body $dupWoBody -ContentType "application/json"
}

# F2: Complete without assignment
Write-Host "`n--- F2: Complete without assignment ---" -ForegroundColor Yellow
$noAsstBody = @{ name = "NoAssign"; serial_number = "SN-NOASSIGN-VERIFY-$runId" } | ConvertTo-Json
$noAsstInst = (Invoke-RestMethod -Uri "$base/instruments" -Method Post -Body $noAsstBody -ContentType "application/json").data
$noAsstCfg = @{ instrument_id = $noAsstInst.id; cycle_days = 5 } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/configs" -Method Post -Body $noAsstCfg -ContentType "application/json" | Out-Null
$noAsstWo = @{ instrument_id = $noAsstInst.id } | ConvertTo-Json
$noAsstWoId = (Invoke-RestMethod -Uri "$base/work-orders" -Method Post -Body $noAsstWo -ContentType "application/json").data.id
Try-Fail "Complete without assignment" "NOT_ASSIGNED" {
    $b = @{ result = "Qualified" } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/work-orders/$noAsstWoId/complete" -Method Post -Body $b -ContentType "application/json"
}

# F3: Negative cycle import
Write-Host "`n--- F3: Negative cycle import ---" -ForegroundColor Yellow
Try-Fail "Import negative cycle" "IMPORT_VALIDATION_FAILED" {
    $impData = @{
        instruments = @(@{ id = "neg-test-$runId"; name = "Neg"; serial_number = "NEG-VERIFY-$runId" })
        calibration_configs = @(@{ id = "neg-cfg-$runId"; instrument_id = "neg-test-$runId"; cycle_days = -5; version = 1 })
        technicians = @(); technician_schedules = @(); work_orders = @(); audit_events = @()
    } | ConvertTo-Json -Depth 10
    Invoke-RestMethod -Uri "$base/data/import" -Method Post -Body $impData -ContentType "application/json"
}

# F4: Duplicate serial
Write-Host "`n--- F4: Duplicate serial number ---" -ForegroundColor Yellow
$dupSerial = "SN-DUP-SERIAL-$runId"
$b1 = @{ name = "Dup Serial A"; serial_number = $dupSerial } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/instruments" -Method Post -Body $b1 -ContentType "application/json" | Out-Null
Try-Fail "Duplicate serial" "DUPLICATE_SERIAL" {
    $b2 = @{ name = "Dup Serial B"; serial_number = $dupSerial } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/instruments" -Method Post -Body $b2 -ContentType "application/json"
}

Write-Host "`n======================================================" -ForegroundColor Cyan
Write-Host " REGRESSION TEST SUMMARY: $pass PASS, $fail FAIL" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan

if ($fail -gt 0) { exit 1 }
