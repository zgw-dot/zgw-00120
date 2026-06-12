$base = "http://localhost:3000/api"
$pass = 0
$fail = 0
$runId = [guid]::NewGuid().ToString("N").Substring(0,8)

$script:inst1Id = $null
$script:cfg1Id = $null
$script:tech1Id = $null
$script:inst2Id = $null
$script:cfg2Id = $null
$script:wo2CreatedId = $null
$script:inst3Id = $null
$script:inst4Id = $null
$script:inst5Id = $null
$script:inst8Id = $null
$script:inst14Id = $null

function Test-Success($name, $script) {
    Write-Host "`n=== PASS TEST: $name ===" -ForegroundColor Green
    try {
        $result = & $script
        Write-Host "OK" -ForegroundColor Green
        $script:pass++
        return $result
    } catch {
        Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message }
        $script:fail++
        return $null
    }
}

function Test-Fail($name, $expectedCode, $script) {
    Write-Host "`n=== FAIL TEST: $name (expect $expectedCode) ===" -ForegroundColor Yellow
    try {
        & $script
        Write-Host "FAILED: expected error but got success" -ForegroundColor Red
        $script:fail++
        return $false
    } catch {
        $resp = $_.ErrorDetails.Message | ConvertFrom-Json
        if ($resp.error.code -eq $expectedCode) {
            Write-Host "OK - got $expectedCode : $($resp.error.message)" -ForegroundColor Green
            $script:pass++
            return $true
        } else {
            Write-Host "FAILED: expected $expectedCode but got $($resp.error.code)" -ForegroundColor Red
            $_.ErrorDetails.Message
            $script:fail++
            return $false
        }
    }
}

# ============================================================
# SC1: Preplay does not write to DB, Confirm does
# ============================================================

Test-Success "SC1.1 Setup: create instrument + config + technician" {
    $instBody = @{ name = "SP-Inst1-$runId"; serial_number = "SP-SN1-$runId" } | ConvertTo-Json
    $inst = Invoke-RestMethod -Uri "$base/instruments" -Method Post -Body $instBody -ContentType "application/json"
    $script:inst1Id = $inst.data.id

    $cfgBody = @{ instrument_id = $script:inst1Id; cycle_days = 30 } | ConvertTo-Json
    $cfg = Invoke-RestMethod -Uri "$base/configs" -Method Post -Body $cfgBody -ContentType "application/json"
    $script:cfg1Id = $cfg.data.id

    $techBody = @{ name = "SP-Tech1-$runId"; employee_id = "SP-EMP1-$runId" } | ConvertTo-Json
    $tech = Invoke-RestMethod -Uri "$base/technicians" -Method Post -Body $techBody -ContentType "application/json"
    $script:tech1Id = $tech.data.id

    $day7s = (Get-Date).AddDays(7).Date.AddHours(9).ToString("yyyy-MM-ddTHH:mm:ss")
    $day7e = (Get-Date).AddDays(7).Date.AddHours(17).ToString("yyyy-MM-ddTHH:mm:ss")
    $schBody = @{ start_time = $day7s; end_time = $day7e; shift_type = "regular" } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/technicians/$script:tech1Id/schedules" -Method Post -Body $schBody -ContentType "application/json"

    $day8s = (Get-Date).AddDays(8).Date.AddHours(9).ToString("yyyy-MM-ddTHH:mm:ss")
    $day8e = (Get-Date).AddDays(8).Date.AddHours(17).ToString("yyyy-MM-ddTHH:mm:ss")
    $schBody2 = @{ start_time = $day8s; end_time = $day8e; shift_type = "regular" } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/technicians/$script:tech1Id/schedules" -Method Post -Body $schBody2 -ContentType "application/json"
}

Test-Success "SC1.2 Preplay does NOT create work order" {
    $woBefore = Invoke-RestMethod -Uri "$base/work-orders?instrument_id=$script:inst1Id" -Method Get
    $countBefore = 0
    if ($woBefore.data) { $countBefore = @($woBefore.data).Count }

    $body = @{
        instrument_id = $script:inst1Id
        technician_id = $script:tech1Id
        scheduled_start = (Get-Date).AddDays(7).Date.AddHours(10).ToString("yyyy-MM-ddTHH:mm:ss")
        scheduled_end = (Get-Date).AddDays(7).Date.AddHours(12).ToString("yyyy-MM-ddTHH:mm:ss")
    } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "$base/schedule/preplay" -Method Post -Body $body -ContentType "application/json"
    if ($r.data.can_schedule -ne $true) { throw "can_schedule should be true, got false: $($r.data.errors | ConvertTo-Json -Compress)" }

    $woAfter = Invoke-RestMethod -Uri "$base/work-orders?instrument_id=$script:inst1Id" -Method Get
    $countAfter = 0
    if ($woAfter.data) { $countAfter = @($woAfter.data).Count }
    if ($countAfter -ne $countBefore) { throw "Preplay should not create work orders! before=$countBefore after=$countAfter" }
    Write-Host "  work_orders count unchanged: $countAfter"
}

Test-Success "SC1.3 Confirm creates and assigns work order" {
    $body = @{
        instrument_id = $script:inst1Id
        technician_id = $script:tech1Id
        scheduled_start = (Get-Date).AddDays(7).Date.AddHours(10).ToString("yyyy-MM-ddTHH:mm:ss")
        scheduled_end = (Get-Date).AddDays(7).Date.AddHours(12).ToString("yyyy-MM-ddTHH:mm:ss")
        operator = "test_admin"
        notes = "SC1 confirm"
    } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "$base/schedule/confirm" -Method Post -Body $body -ContentType "application/json"
    if ($r.data.status -ne 'assigned') { throw "expected status=assigned, got $($r.data.status)" }
    if ($r.data.technician_id -ne $script:tech1Id) { throw "technician_id mismatch" }
    if ($r.meta.is_new_order -ne $true) { throw "expected is_new_order=true" }
    if ($r.meta.confirmed_by -ne 'test_admin') { throw "expected confirmed_by=test_admin" }
    if ($r.meta.config_snapshot.config_id -ne $script:cfg1Id) { throw "config_snapshot.config_id mismatch" }
    if ($r.meta.config_snapshot.cycle_days -ne 30) { throw "config_snapshot.cycle_days should be 30" }
    Write-Host "  order_id=$($r.data.id), status=$($r.data.status), is_new=$($r.meta.is_new_order), by=$($r.meta.confirmed_by)"
}

# ============================================================
# SC2: Confirm reuses existing 'created' work order
# ============================================================

Test-Success "SC2.1 Setup: create instrument + config + created work order" {
    $instBody = @{ name = "SP-Inst2-$runId"; serial_number = "SP-SN2-$runId" } | ConvertTo-Json
    $inst = Invoke-RestMethod -Uri "$base/instruments" -Method Post -Body $instBody -ContentType "application/json"
    $script:inst2Id = $inst.data.id

    $cfgBody = @{ instrument_id = $script:inst2Id; cycle_days = 60 } | ConvertTo-Json
    $cfg = Invoke-RestMethod -Uri "$base/configs" -Method Post -Body $cfgBody -ContentType "application/json"
    $script:cfg2Id = $cfg.data.id

    $woBody = @{ instrument_id = $script:inst2Id } | ConvertTo-Json
    $wo = Invoke-RestMethod -Uri "$base/work-orders" -Method Post -Body $woBody -ContentType "application/json"
    $script:wo2CreatedId = $wo.data.id
    Write-Host "  existing WO id=$($wo.data.id), status=$($wo.data.status)"
}

Test-Success "SC2.2 Confirm reuses created work order (is_new_order=false)" {
    $body = @{
        instrument_id = $script:inst2Id
        technician_id = $script:tech1Id
        scheduled_start = (Get-Date).AddDays(7).Date.AddHours(13).ToString("yyyy-MM-ddTHH:mm:ss")
        scheduled_end = (Get-Date).AddDays(7).Date.AddHours(15).ToString("yyyy-MM-ddTHH:mm:ss")
        operator = "test_admin2"
    } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "$base/schedule/confirm" -Method Post -Body $body -ContentType "application/json"
    if ($r.data.id -ne $script:wo2CreatedId) { throw "should reuse existing WO, got new id=$($r.data.id)" }
    if ($r.meta.is_new_order -ne $false) { throw "expected is_new_order=false" }
    if ($r.data.status -ne 'assigned') { throw "expected status=assigned" }
    if ($r.meta.config_snapshot.config_id -ne $script:cfg2Id) { throw "config_snapshot.config_id mismatch, expected $script:cfg2Id, got $($r.meta.config_snapshot.config_id)" }
    Write-Host "  reused WO id=$($r.data.id), is_new=$($r.meta.is_new_order)"
}

# ============================================================
# SC3: Same technician overlapping time rejected
# ============================================================

Test-Success "SC3.1 Preplay rejects overlapping time for same technician" {
    $instBody = @{ name = "SP-Inst3-$runId"; serial_number = "SP-SN3-$runId" } | ConvertTo-Json
    $inst3 = Invoke-RestMethod -Uri "$base/instruments" -Method Post -Body $instBody -ContentType "application/json"
    $script:inst3Id = $inst3.data.id

    $cfgBody = @{ instrument_id = $script:inst3Id; cycle_days = 45 } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/configs" -Method Post -Body $cfgBody -ContentType "application/json"

    $body = @{
        instrument_id = $script:inst3Id
        technician_id = $script:tech1Id
        scheduled_start = (Get-Date).AddDays(7).Date.AddHours(10).ToString("yyyy-MM-ddTHH:mm:ss")
        scheduled_end = (Get-Date).AddDays(7).Date.AddHours(12).ToString("yyyy-MM-ddTHH:mm:ss")
    } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "$base/schedule/preplay" -Method Post -Body $body -ContentType "application/json"
    if ($r.data.can_schedule -ne $false) { throw "should reject overlapping time" }
    $hasConflict = $false
    foreach ($e in $r.data.errors) {
        if ($e.code -eq 'WORK_ORDER_CONFLICT') { $hasConflict = $true }
    }
    if (-not $hasConflict) { throw "expected WORK_ORDER_CONFLICT error, got: $($r.data.errors | ConvertTo-Json -Compress)" }
    Write-Host "  correctly rejected: WORK_ORDER_CONFLICT, conflict_orders count=$($r.data.conflict_orders.Count)"
}

Test-Fail "SC3.2 Confirm rejects overlapping time for same technician" "WORK_ORDER_CONFLICT" {
    $body = @{
        instrument_id = $script:inst3Id
        technician_id = $script:tech1Id
        scheduled_start = (Get-Date).AddDays(7).Date.AddHours(10).ToString("yyyy-MM-ddTHH:mm:ss")
        scheduled_end = (Get-Date).AddDays(7).Date.AddHours(12).ToString("yyyy-MM-ddTHH:mm:ss")
    } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/schedule/confirm" -Method Post -Body $body -ContentType "application/json"
}

# ============================================================
# SC4: No active config gives readable error
# ============================================================

Test-Success "SC4.1 Preplay: no active config gives readable error" {
    $instBody = @{ name = "SP-Inst4-$runId"; serial_number = "SP-SN4-$runId" } | ConvertTo-Json
    $inst4 = Invoke-RestMethod -Uri "$base/instruments" -Method Post -Body $instBody -ContentType "application/json"
    $script:inst4Id = $inst4.data.id

    $body = @{
        instrument_id = $script:inst4Id
        technician_id = $script:tech1Id
        scheduled_start = (Get-Date).AddDays(8).Date.AddHours(10).ToString("yyyy-MM-ddTHH:mm:ss")
        scheduled_end = (Get-Date).AddDays(8).Date.AddHours(12).ToString("yyyy-MM-ddTHH:mm:ss")
    } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "$base/schedule/preplay" -Method Post -Body $body -ContentType "application/json"
    if ($r.data.can_schedule -ne $false) { throw "should reject no active config" }
    $hasNoConfig = $false
    foreach ($e in $r.data.errors) {
        if ($e.code -eq 'NO_ACTIVE_CONFIG') { $hasNoConfig = $true; Write-Host "  message: $($e.message)" }
    }
    if (-not $hasNoConfig) { throw "expected NO_ACTIVE_CONFIG error" }
}

Test-Fail "SC4.2 Confirm: no active config gives readable error" "NO_ACTIVE_CONFIG" {
    $body = @{
        instrument_id = $script:inst4Id
        technician_id = $script:tech1Id
        scheduled_start = (Get-Date).AddDays(8).Date.AddHours(10).ToString("yyyy-MM-ddTHH:mm:ss")
        scheduled_end = (Get-Date).AddDays(8).Date.AddHours(12).ToString("yyyy-MM-ddTHH:mm:ss")
    } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/schedule/confirm" -Method Post -Body $body -ContentType "application/json"
}

# ============================================================
# SC5: Non-active instrument gives readable error
# ============================================================

Test-Success "SC5.1 Preplay: non-active instrument gives readable error" {
    $instBody = @{ name = "SP-Inst5-$runId"; serial_number = "SP-SN5-$runId" } | ConvertTo-Json
    $inst5 = Invoke-RestMethod -Uri "$base/instruments" -Method Post -Body $instBody -ContentType "application/json"
    $script:inst5Id = $inst5.data.id

    $cfgBody = @{ instrument_id = $script:inst5Id; cycle_days = 30 } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/configs" -Method Post -Body $cfgBody -ContentType "application/json"

    $updateBody = @{ status = "inactive" } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/instruments/$script:inst5Id" -Method Put -Body $updateBody -ContentType "application/json"

    $body = @{
        instrument_id = $script:inst5Id
        technician_id = $script:tech1Id
        scheduled_start = (Get-Date).AddDays(7).Date.AddHours(10).ToString("yyyy-MM-ddTHH:mm:ss")
        scheduled_end = (Get-Date).AddDays(7).Date.AddHours(12).ToString("yyyy-MM-ddTHH:mm:ss")
    } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "$base/schedule/preplay" -Method Post -Body $body -ContentType "application/json"
    if ($r.data.can_schedule -ne $false) { throw "should reject inactive instrument" }
    $hasInactive = $false
    foreach ($e in $r.data.errors) {
        if ($e.code -eq 'INSTRUMENT_NOT_ACTIVE') { $hasInactive = $true; Write-Host "  message: $($e.message)" }
    }
    if (-not $hasInactive) { throw "expected INSTRUMENT_NOT_ACTIVE error" }
}

Test-Fail "SC5.2 Confirm: non-active instrument gives readable error" "INSTRUMENT_NOT_ACTIVE" {
    $body = @{
        instrument_id = $script:inst5Id
        technician_id = $script:tech1Id
        scheduled_start = "2026-07-01T09:00:00"
        scheduled_end = "2026-07-01T11:00:00"
    } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/schedule/confirm" -Method Post -Body $body -ContentType "application/json"
}

# ============================================================
# SC6: Confirm audit log contains operator and config snapshot
# ============================================================

Test-Success "SC6 Audit log contains operator and config snapshot" {
    $auditR = Invoke-RestMethod -Uri "$base/audit?entity_type=work_order&entity_id=$script:wo2CreatedId&limit=20" -Method Get
    $confirmAudit = $null
    foreach ($a in $auditR.data) {
        if ($a.event_type -eq 'SCHEDULE_CONFIRM') { $confirmAudit = $a; break }
    }
    if (-not $confirmAudit) { throw "SCHEDULE_CONFIRM audit event not found for WO $script:wo2CreatedId" }
    $newVals = $confirmAudit.new_values
    if ($newVals -is [string]) { $newVals = $newVals | ConvertFrom-Json }
    if ($newVals.confirmed_by -ne 'test_admin2') { throw "expected confirmed_by=test_admin2, got $($newVals.confirmed_by)" }
    if (-not $newVals.config_snapshot) { throw "config_snapshot missing in audit" }
    if ($newVals.config_snapshot.config_id -ne $script:cfg2Id) { throw "config_snapshot.config_id mismatch in audit: expected $script:cfg2Id, got $($newVals.config_snapshot.config_id)" }
    Write-Host "  audit: confirmed_by=$($newVals.confirmed_by), snapshot.config_id=$($newVals.config_snapshot.config_id), snapshot.cycle_days=$($newVals.config_snapshot.cycle_days)"
}

# ============================================================
# SC7: Preplay returns matched shifts, config snapshot, next_due_date
# (using fresh technician with no conflicts)
# ============================================================

Test-Success "SC7 Preplay returns matched shifts, config snapshot, next_due_date" {
    $instBody = @{ name = "SP-Inst7-$runId"; serial_number = "SP-SN7-$runId" } | ConvertTo-Json
    $inst7 = Invoke-RestMethod -Uri "$base/instruments" -Method Post -Body $instBody -ContentType "application/json"
    $inst7Id = $inst7.data.id

    $cfgBody = @{ instrument_id = $inst7Id; cycle_days = 90 } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/configs" -Method Post -Body $cfgBody -ContentType "application/json"

    $body = @{
        instrument_id = $inst7Id
        technician_id = $script:tech1Id
        scheduled_start = (Get-Date).AddDays(8).Date.AddHours(10).ToString("yyyy-MM-ddTHH:mm:ss")
        scheduled_end = (Get-Date).AddDays(8).Date.AddHours(12).ToString("yyyy-MM-ddTHH:mm:ss")
    } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "$base/schedule/preplay" -Method Post -Body $body -ContentType "application/json"
    if ($r.data.can_schedule -ne $true) { throw "should be schedulable, errors: $($r.data.errors | ConvertTo-Json -Compress)" }
    if ($r.data.matched_shifts.Count -lt 1) { throw "expected matched_shifts >= 1" }
    if (-not $r.data.active_config_snapshot) { throw "active_config_snapshot missing" }
    if ($r.data.active_config_snapshot.cycle_days -ne 90) { throw "expected cycle_days=90" }
    if (-not $r.data.next_due_date) { throw "next_due_date missing" }
    if (-not $r.data.next_due_date_calc) { throw "next_due_date_calc missing" }
    Write-Host "  matched_shifts=$($r.data.matched_shifts.Count), config.cycle_days=$($r.data.active_config_snapshot.cycle_days), next_due=$($r.data.next_due_date), cycle_source=$($r.data.next_due_date_calc.cycle_source)"
}

# ============================================================
# SC8: Preplay result stable across repeated calls (deterministic)
# ============================================================

Test-Success "SC8 Preplay is deterministic (3 calls, same result)" {
    $instBody = @{ name = "SP-Inst8-$runId"; serial_number = "SP-SN8-$runId" } | ConvertTo-Json
    $inst8 = Invoke-RestMethod -Uri "$base/instruments" -Method Post -Body $instBody -ContentType "application/json"
    $script:inst8Id = $inst8.data.id

    $cfgBody = @{ instrument_id = $script:inst8Id; cycle_days = 120 } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/configs" -Method Post -Body $cfgBody -ContentType "application/json"

    $body = @{
        instrument_id = $script:inst8Id
        technician_id = $script:tech1Id
        scheduled_start = (Get-Date).AddDays(8).Date.AddHours(13).ToString("yyyy-MM-ddTHH:mm:ss")
        scheduled_end = (Get-Date).AddDays(8).Date.AddHours(15).ToString("yyyy-MM-ddTHH:mm:ss")
    } | ConvertTo-Json
    $r1 = Invoke-RestMethod -Uri "$base/schedule/preplay" -Method Post -Body $body -ContentType "application/json"
    $r2 = Invoke-RestMethod -Uri "$base/schedule/preplay" -Method Post -Body $body -ContentType "application/json"
    $r3 = Invoke-RestMethod -Uri "$base/schedule/preplay" -Method Post -Body $body -ContentType "application/json"

    $j1 = $r1.data | ConvertTo-Json -Compress
    $j2 = $r2.data | ConvertTo-Json -Compress
    $j3 = $r3.data | ConvertTo-Json -Compress

    $j1compare = $j1 -replace '"validated_at":"[^"]*"', ''
    $j2compare = $j2 -replace '"validated_at":"[^"]*"', ''
    $j3compare = $j3 -replace '"validated_at":"[^"]*"', ''

    if ($j1compare -ne $j2compare -or $j2compare -ne $j3compare) { throw "Preplay results not deterministic" }
    Write-Host "  3 calls produce identical results (excluding validated_at)"
}

# ============================================================
# SC9: Preplay with no schedule shift gives SCHEDULE_CONFLICT
# ============================================================

Test-Success "SC9.1 Preplay: no shift gives SCHEDULE_CONFLICT" {
    $techBody = @{ name = "SP-Tech9-$runId"; employee_id = "SP-EMP9-$runId" } | ConvertTo-Json
    $tech9 = Invoke-RestMethod -Uri "$base/technicians" -Method Post -Body $techBody -ContentType "application/json"
    $script:tech9Id = $tech9.data.id

    $body = @{
        instrument_id = $script:inst8Id
        technician_id = $script:tech9Id
        scheduled_start = (Get-Date).AddDays(7).Date.AddHours(10).ToString("yyyy-MM-ddTHH:mm:ss")
        scheduled_end = (Get-Date).AddDays(7).Date.AddHours(12).ToString("yyyy-MM-ddTHH:mm:ss")
    } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "$base/schedule/preplay" -Method Post -Body $body -ContentType "application/json"
    if ($r.data.can_schedule -ne $false) { throw "should reject no shift" }
    $hasScheduleConflict = $false
    foreach ($e in $r.data.errors) {
        if ($e.code -eq 'SCHEDULE_CONFLICT') { $hasScheduleConflict = $true }
    }
    if (-not $hasScheduleConflict) { throw "expected SCHEDULE_CONFLICT" }
    Write-Host "  correctly rejected: SCHEDULE_CONFLICT"
}

Test-Fail "SC9.2 Confirm: no shift gives SCHEDULE_CONFLICT" "SCHEDULE_CONFLICT" {
    $body = @{
        instrument_id = $script:inst8Id
        technician_id = $script:tech9Id
        scheduled_start = (Get-Date).AddDays(7).Date.AddHours(10).ToString("yyyy-MM-ddTHH:mm:ss")
        scheduled_end = (Get-Date).AddDays(7).Date.AddHours(12).ToString("yyyy-MM-ddTHH:mm:ss")
    } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/schedule/confirm" -Method Post -Body $body -ContentType "application/json"
}

# ============================================================
# SC10: Preplay with inactive technician gives TECHNICIAN_NOT_ACTIVE
# ============================================================

Test-Success "SC10 Preplay: inactive technician gives TECHNICIAN_NOT_ACTIVE" {
    $techBody = @{ name = "SP-Tech10-$runId"; employee_id = "SP-EMP10-$runId" } | ConvertTo-Json
    $tech10 = Invoke-RestMethod -Uri "$base/technicians" -Method Post -Body $techBody -ContentType "application/json"
    $script:tech10Id = $tech10.data.id

    $updateBody = @{ status = "inactive" } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/technicians/$script:tech10Id" -Method Put -Body $updateBody -ContentType "application/json"

    $body = @{
        instrument_id = $script:inst8Id
        technician_id = $script:tech10Id
        scheduled_start = (Get-Date).AddDays(7).Date.AddHours(10).ToString("yyyy-MM-ddTHH:mm:ss")
        scheduled_end = (Get-Date).AddDays(7).Date.AddHours(12).ToString("yyyy-MM-ddTHH:mm:ss")
    } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "$base/schedule/preplay" -Method Post -Body $body -ContentType "application/json"
    if ($r.data.can_schedule -ne $false) { throw "should reject inactive technician" }
    $hasInactiveTech = $false
    foreach ($e in $r.data.errors) {
        if ($e.code -eq 'TECHNICIAN_NOT_ACTIVE') { $hasInactiveTech = $true; Write-Host "  message: $($e.message)" }
    }
    if (-not $hasInactiveTech) { throw "expected TECHNICIAN_NOT_ACTIVE" }
}

# ============================================================
# SC11: Preplay with duplicate non-created open order gives DUPLICATE_OPEN_ORDER
# ============================================================

Test-Success "SC11 Preplay: assigned order gives DUPLICATE_OPEN_ORDER" {
    $body = @{
        instrument_id = $script:inst1Id
        technician_id = $script:tech1Id
        scheduled_start = (Get-Date).AddDays(7).Date.AddHours(14).ToString("yyyy-MM-ddTHH:mm:ss")
        scheduled_end = (Get-Date).AddDays(7).Date.AddHours(16).ToString("yyyy-MM-ddTHH:mm:ss")
    } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "$base/schedule/preplay" -Method Post -Body $body -ContentType "application/json"
    if ($r.data.can_schedule -ne $false) { throw "should reject duplicate open order" }
    $hasDup = $false
    foreach ($e in $r.data.errors) {
        if ($e.code -eq 'DUPLICATE_OPEN_ORDER') { $hasDup = $true }
    }
    if (-not $hasDup) { throw "expected DUPLICATE_OPEN_ORDER, got: $($r.data.errors | ConvertTo-Json -Compress)" }
    Write-Host "  correctly rejected: DUPLICATE_OPEN_ORDER"
}

# ============================================================
# SC12: Export/import preserves conflict detection
# ============================================================

Test-Success "SC12 Export/import preserves conflict detection" {
    $exportR = Invoke-RestMethod -Uri "$base/data/export" -Method Get
    $exportData = $exportR.data | ConvertTo-Json -Depth 10

    $importR = Invoke-RestMethod -Uri "$base/data/import" -Method Post -Body $exportData -ContentType "application/json"

    $body = @{
        instrument_id = $script:inst1Id
        technician_id = $script:tech1Id
        scheduled_start = (Get-Date).AddDays(7).Date.AddHours(10).ToString("yyyy-MM-ddTHH:mm:ss")
        scheduled_end = (Get-Date).AddDays(7).Date.AddHours(12).ToString("yyyy-MM-ddTHH:mm:ss")
    } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "$base/schedule/preplay" -Method Post -Body $body -ContentType "application/json"
    if ($r.data.can_schedule -ne $false) { throw "After import, overlapping preplay should still be rejected" }
    $hasConflict = $false
    foreach ($e in $r.data.errors) {
        if ($e.code -eq 'WORK_ORDER_CONFLICT' -or $e.code -eq 'DUPLICATE_OPEN_ORDER') { $hasConflict = $true }
    }
    if (-not $hasConflict) { throw "expected conflict after import, got: $($r.data.errors | ConvertTo-Json -Compress)" }
    Write-Host "  conflict still detected after import: OK"
}

# ============================================================
# SC13: Overdue/explain still works after schedule operations
# ============================================================

Test-Success "SC13 Overdue explain still works after schedule operations" {
    $r = Invoke-RestMethod -Uri "$base/overdue/explain?instrument_id=$script:inst1Id&include_non_overdue=true" -Method Get
    if ($r.data.Count -lt 1) { throw "overdue explain should return results" }
    $explanation = $r.data[0]
    if (-not $explanation.base_calculation) { throw "base_calculation missing" }
    if (-not $explanation.trace) { throw "trace missing" }
    Write-Host "  overdue explain: is_overdue=$($explanation.base_calculation.is_overdue), cycle_source=$($explanation.trace.cycle_source)"
}

Test-Success "SC13.2 Reconciliation still works after schedule operations" {
    $r = Invoke-RestMethod -Uri "$base/overdue/reconciliation?include_non_overdue=true" -Method Get
    if (-not $r.data.summary) { throw "reconciliation summary missing" }
    Write-Host "  reconciliation: total=$($r.data.summary.total_instruments), overdue=$($r.data.summary.overdue_count)"
}

# ============================================================
# SC14: Confirm full flow - create + complete + verify + next due date
# ============================================================

Test-Success "SC14 Full schedule flow: confirm -> complete -> verify -> check overdue" {
    $instBody = @{ name = "SP-Inst14-$runId"; serial_number = "SP-SN14-$runId" } | ConvertTo-Json
    $inst14 = Invoke-RestMethod -Uri "$base/instruments" -Method Post -Body $instBody -ContentType "application/json"
    $script:inst14Id = $inst14.data.id

    $cfgBody = @{ instrument_id = $script:inst14Id; cycle_days = 7 } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/configs" -Method Post -Body $cfgBody -ContentType "application/json"

    $day9s = (Get-Date).AddDays(9).Date.AddHours(9).ToString("yyyy-MM-ddTHH:mm:ss")
    $day9e = (Get-Date).AddDays(9).Date.AddHours(17).ToString("yyyy-MM-ddTHH:mm:ss")
    $schBody = @{ start_time = $day9s; end_time = $day9e; shift_type = "regular" } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/technicians/$script:tech1Id/schedules" -Method Post -Body $schBody -ContentType "application/json"

    $confirmBody = @{
        instrument_id = $script:inst14Id
        technician_id = $script:tech1Id
        scheduled_start = (Get-Date).AddDays(9).Date.AddHours(10).ToString("yyyy-MM-ddTHH:mm:ss")
        scheduled_end = (Get-Date).AddDays(9).Date.AddHours(12).ToString("yyyy-MM-ddTHH:mm:ss")
        operator = "sc14_admin"
    } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "$base/schedule/confirm" -Method Post -Body $confirmBody -ContentType "application/json"
    $woId = $r.data.id
    if ($r.data.status -ne 'assigned') { throw "expected assigned" }

    $compBody = @{ result = "Qualified"; certificate_no = "CERT-SC14" } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/work-orders/$woId/complete" -Method Post -Body $compBody -ContentType "application/json"

    $verBody = @{ verified_by = "SC14 Verifier"; operator = "sc14_admin" } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/work-orders/$woId/verify" -Method Post -Body $verBody -ContentType "application/json"

    $asOf = (Get-Date).AddDays(30).ToString("yyyy-MM-dd")
    $explainR = Invoke-RestMethod -Uri "$base/overdue/explain/${script:inst14Id}?as_of=${asOf}" -Method Get
    if ($explainR.data.base_calculation.is_overdue -ne $true) { throw "should be overdue 30 days out with 7-day cycle" }
    Write-Host "  overdue after 30 days (7-day cycle): is_overdue=$($explainR.data.base_calculation.is_overdue), days_overdue=$($explainR.data.base_calculation.days_overdue)"
}

# ============================================================
# SUMMARY
# ============================================================

Write-Host "`n`n=========================================" -ForegroundColor Cyan
Write-Host " SCHEDULE PREPLAY/CONFIRM E2E TEST" -ForegroundColor Cyan
Write-Host " $pass PASS, $fail FAIL" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

if ($fail -gt 0) { exit 1 }
