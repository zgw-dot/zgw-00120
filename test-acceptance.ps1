$base = "http://localhost:3000/api"
$pass = 0
$fail = 0

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
# SUCCESS TESTS
# ============================================================

# 1. Health check
Test-Success "Health check" {
    $r = Invoke-RestMethod -Uri "http://localhost:3000/health" -Method Get
    if ($r.status -ne 'ok') { throw "unexpected" }
}

# 2. Add instrument
$instrumentId = $null
Test-Success "Add instrument" {
    $body = @{
        name = "Pressure Gauge A"
        serial_number = "SN-2026-001"
        model = "PG-100"
        manufacturer = "TestCo"
        location = "Lab A"
        description = "Digital pressure gauge"
    } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "$base/instruments" -Method Post -Body $body -ContentType "application/json"
    $script:instrumentId = $r.data.id
    Write-Host "  instrument_id: $script:instrumentId"
}

# 3. Add calibration config
$configId = $null
Test-Success "Add calibration config (90 days)" {
    $body = @{
        instrument_id = $instrumentId
        cycle_days = 90
        description = "Standard quarterly calibration"
    } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "$base/configs" -Method Post -Body $body -ContentType "application/json"
    $script:configId = $r.data.id
    Write-Host "  config_id: $script:configId, version: $($r.data.version)"
}

# 4. Add technician
$technicianId = $null
Test-Success "Add technician" {
    $body = @{
        name = "Wang Gong"
        employee_id = "EMP-001"
        phone = "13800138001"
        specialty = "Pressure calibration"
    } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "$base/technicians" -Method Post -Body $body -ContentType "application/json"
    $script:technicianId = $r.data.id
    Write-Host "  technician_id: $script:technicianId"
}

# 5. Add technician schedules (next 3 days: Day 7, 8, 9)
$d7s = (Get-Date).AddDays(7).Date.AddHours(9).ToString("yyyy-MM-ddTHH:mm:ss")
$d7e = (Get-Date).AddDays(7).Date.AddHours(17).ToString("yyyy-MM-ddTHH:mm:ss")
$d8s = (Get-Date).AddDays(8).Date.AddHours(9).ToString("yyyy-MM-ddTHH:mm:ss")
$d8e = (Get-Date).AddDays(8).Date.AddHours(17).ToString("yyyy-MM-ddTHH:mm:ss")
$d9s = (Get-Date).AddDays(9).Date.AddHours(9).ToString("yyyy-MM-ddTHH:mm:ss")
$d9e = (Get-Date).AddDays(9).Date.AddHours(17).ToString("yyyy-MM-ddTHH:mm:ss")

Test-Success "Add technician schedule (Day 7)" {
    $body = @{ start_time = $d7s; end_time = $d7e; shift_type = "regular" } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "$base/technicians/$technicianId/schedules" -Method Post -Body $body -ContentType "application/json"
    Write-Host "  schedule_id: $($r.data.id)"
}
Test-Success "Add technician schedule (Day 8)" {
    $body = @{ start_time = $d8s; end_time = $d8e; shift_type = "regular" } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "$base/technicians/$technicianId/schedules" -Method Post -Body $body -ContentType "application/json"
    Write-Host "  schedule_id: $($r.data.id)"
}
Test-Success "Add technician schedule (Day 9)" {
    $body = @{ start_time = $d9s; end_time = $d9e; shift_type = "regular" } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "$base/technicians/$technicianId/schedules" -Method Post -Body $body -ContentType "application/json"
    Write-Host "  schedule_id: $($r.data.id)"
}

# 6. Create work order
$workOrderId = $null
Test-Success "Create work order" {
    $body = @{
        instrument_id = $instrumentId
        planned_date = (Get-Date).AddDays(7).ToString("yyyy-MM-dd")
        priority = "normal"
    } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "$base/work-orders" -Method Post -Body $body -ContentType "application/json"
    $script:workOrderId = $r.data.id
    Write-Host "  work_order_id: $script:workOrderId, status: $($r.data.status)"
}

# 7. Assign work order (Day 7, 10am-12pm)
$assignStart = (Get-Date).AddDays(7).Date.AddHours(10).ToString("yyyy-MM-ddTHH:mm:ss")
$assignEnd = (Get-Date).AddDays(7).Date.AddHours(12).ToString("yyyy-MM-ddTHH:mm:ss")
Test-Success "Assign work order" {
    $body = @{
        technician_id = $technicianId
        scheduled_start = $assignStart
        scheduled_end = $assignEnd
    } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "$base/work-orders/$workOrderId/assign" -Method Post -Body $body -ContentType "application/json"
    Write-Host "  status: $($r.data.status)"
}

# 8. Complete work order
Test-Success "Complete work order" {
    $body = @{
        result = "Qualified"
        deviation = "+0.15%"
        certificate_no = "CERT-2026-001"
        notes = "All tests passed"
    } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "$base/work-orders/$workOrderId/complete" -Method Post -Body $body -ContentType "application/json"
    Write-Host "  status: $($r.data.status), result: $($r.data.result)"
}

# 9. Verify work order
Test-Success "Verify work order" {
    $body = @{ verified_by = "Director Li" } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "$base/work-orders/$workOrderId/verify" -Method Post -Body $body -ContentType "application/json"
    Write-Host "  status: $($r.data.status), verified_by: $($r.data.verified_by)"
}

# 10. Calculate overdue list
Test-Success "Calculate overdue list" {
    $r = Invoke-RestMethod -Uri "$base/overdue" -Method Get
    Write-Host "  overdue count: $($r.data.Count)"
}

# 11. Export data
$exportData = $null
Test-Success "Export JSON data" {
    $r = Invoke-RestMethod -Uri "$base/data/export" -Method Get
    $script:exportData = $r.data
    Write-Host "  instruments: $($script:exportData.instruments.Count)"
    Write-Host "  calibration_configs: $($script:exportData.calibration_configs.Count)"
    Write-Host "  technicians: $($script:exportData.technicians.Count)"
    Write-Host "  work_orders: $($script:exportData.work_orders.Count)"
    Write-Host "  audit_events: $($script:exportData.audit_events.Count)"
}

# 12. Audit events
Test-Success "Query audit events" {
    $r = Invoke-RestMethod -Uri "$base/audit?entity_type=work_order&limit=5" -Method Get
    Write-Host "  audit events count: $($r.data.Count)"
}

# 13. Config versioning - create new config, verify version increment and old is inactive
Test-Success "Config versioning: new config increments version" {
    $body = @{ instrument_id = $instrumentId; cycle_days = 120 } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "$base/configs" -Method Post -Body $body -ContentType "application/json"
    Write-Host "  new version: $($r.data.version), is_active: $($r.data.is_active)"
    if ($r.data.version -ne 2) { throw "expected version 2" }
    # check old config is inactive
    $cfgs = (Invoke-RestMethod -Uri "$base/configs?instrument_id=$instrumentId" -Method Get).data
    $oldActive = $cfgs | Where-Object { $_.version -eq 1 -and $_.is_active -eq 1 }
    if ($oldActive) { throw "old config should be inactive" }
    Write-Host "  old config (v1) is now inactive: OK"
}

# 14. Return and reassign workflow
$woReturnId = $null
Test-Success "Return & reassign full workflow" {
    $instBody = @{ name = "Temp Sensor B"; serial_number = "SN-2026-TMP" } | ConvertTo-Json
    $inst = Invoke-RestMethod -Uri "$base/instruments" -Method Post -Body $instBody -ContentType "application/json"
    $cfgBody = @{ instrument_id = $inst.data.id; cycle_days = 180 } | ConvertTo-Json
    $cfg = Invoke-RestMethod -Uri "$base/configs" -Method Post -Body $cfgBody -ContentType "application/json"
    $woBody = @{ instrument_id = $inst.data.id } | ConvertTo-Json
    $wo = Invoke-RestMethod -Uri "$base/work-orders" -Method Post -Body $woBody -ContentType "application/json"
    $script:woReturnId = $wo.data.id
    
    # assign (Day 8, 9-11am)
    $asBody = @{
        technician_id = $technicianId
        scheduled_start = (Get-Date).AddDays(8).Date.AddHours(9).ToString("yyyy-MM-ddTHH:mm:ss")
        scheduled_end = (Get-Date).AddDays(8).Date.AddHours(11).ToString("yyyy-MM-ddTHH:mm:ss")
    } | ConvertTo-Json
    $wo = Invoke-RestMethod -Uri "$base/work-orders/$script:woReturnId/assign" -Method Post -Body $asBody -ContentType "application/json"
    Write-Host "  assigned: status=$($wo.data.status)"
    
    # complete
    $cpBody = @{ result = "Conditional Pass"; deviation = "-0.5%" } | ConvertTo-Json
    $wo = Invoke-RestMethod -Uri "$base/work-orders/$script:woReturnId/complete" -Method Post -Body $cpBody -ContentType "application/json"
    Write-Host "  completed: status=$($wo.data.status)"
    
    # return
    $rtBody = @{ notes = "Need recalibration" } | ConvertTo-Json
    $wo = Invoke-RestMethod -Uri "$base/work-orders/$script:woReturnId/return" -Method Post -Body $rtBody -ContentType "application/json"
    Write-Host "  returned: status=$($wo.data.status)"
    
    # reassign (Day 9, 9-11am)
    $raBody = @{
        technician_id = $technicianId
        scheduled_start = (Get-Date).AddDays(9).Date.AddHours(9).ToString("yyyy-MM-ddTHH:mm:ss")
        scheduled_end = (Get-Date).AddDays(9).Date.AddHours(11).ToString("yyyy-MM-ddTHH:mm:ss")
    } | ConvertTo-Json
    $wo = Invoke-RestMethod -Uri "$base/work-orders/$script:woReturnId/reassign" -Method Post -Body $raBody -ContentType "application/json"
    Write-Host "  reassigned: status=$($wo.data.status)"

    # verify config snapshot didn't change (historical trace)
    $woDetail = (Invoke-RestMethod -Uri "$base/work-orders/$script:woReturnId" -Method Get).data
    Write-Host "  cycle_days_snapshot: $($woDetail.cycle_days_snapshot) (should be 180, frozen at creation)"
}

# 15. Data persistence - restart simulation (just re-read data)
Test-Success "Data persistence: verify data still accessible" {
    $insts = (Invoke-RestMethod -Uri "$base/instruments" -Method Get).data
    $wos = (Invoke-RestMethod -Uri "$base/work-orders" -Method Get).data
    $audits = (Invoke-RestMethod -Uri "$base/audit?limit=100" -Method Get).data
    Write-Host "  instruments: $($insts.Count), work_orders: $($wos.Count), audits: $($audits.Count)"
    if ($insts.Count -lt 2) { throw "missing instrument data" }
}

# ============================================================
# FAILURE TESTS
# ============================================================

# F1. Complete without assignment
$woNoAssignId = $null
Test-Success "Setup: create work order (unassigned)" {
    $instBody = @{ name = "Test Meter"; serial_number = "SN-TEST-001" } | ConvertTo-Json
    $inst = Invoke-RestMethod -Uri "$base/instruments" -Method Post -Body $instBody -ContentType "application/json"
    $cfgBody = @{ instrument_id = $inst.data.id; cycle_days = 30 } | ConvertTo-Json
    $cfg = Invoke-RestMethod -Uri "$base/configs" -Method Post -Body $cfgBody -ContentType "application/json"
    $woBody = @{ instrument_id = $inst.data.id } | ConvertTo-Json
    $wo = Invoke-RestMethod -Uri "$base/work-orders" -Method Post -Body $woBody -ContentType "application/json"
    $script:woNoAssignId = $wo.data.id
}
Test-Fail "Complete without assignment" "NOT_ASSIGNED" {
    $body = @{ result = "Qualified" } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/work-orders/$woNoAssignId/complete" -Method Post -Body $body -ContentType "application/json"
}

# F2. Duplicate open work order (use the returned one which is in 'assigned' after reassign)
Test-Fail "Duplicate open work order for same instrument" "DUPLICATE_OPEN_ORDER" {
    # woReturnId's instrument currently has an open (assigned) work order
    $woInstId = (Invoke-RestMethod -Uri "$base/work-orders/$woReturnId" -Method Get).data.instrument_id
    $body = @{ instrument_id = $woInstId } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/work-orders" -Method Post -Body $body -ContentType "application/json"
}

# F3. Technician schedule conflict - assign outside shift hours
$woConflictId = $null
Test-Success "Setup: create work order for conflict test" {
    $instBody = @{ name = "Oscilloscope C"; serial_number = "SN-OSC-001" } | ConvertTo-Json
    $inst = Invoke-RestMethod -Uri "$base/instruments" -Method Post -Body $instBody -ContentType "application/json"
    $cfgBody = @{ instrument_id = $inst.data.id; cycle_days = 60 } | ConvertTo-Json
    $cfg = Invoke-RestMethod -Uri "$base/configs" -Method Post -Body $cfgBody -ContentType "application/json"
    $woBody = @{ instrument_id = $inst.data.id } | ConvertTo-Json
    $wo = Invoke-RestMethod -Uri "$base/work-orders" -Method Post -Body $woBody -ContentType "application/json"
    $script:woConflictId = $wo.data.id
}
Test-Fail "Technician not scheduled (no matching shift)" "SCHEDULE_CONFLICT" {
    $body = @{
        technician_id = $technicianId
        scheduled_start = (Get-Date).AddDays(30).Date.AddHours(9).ToString("yyyy-MM-ddTHH:mm:ss")
        scheduled_end = (Get-Date).AddDays(30).Date.AddHours(11).ToString("yyyy-MM-ddTHH:mm:ss")
    } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/work-orders/$woConflictId/assign" -Method Post -Body $body -ContentType "application/json"
}

# F3b. Two work orders overlapping (technician double-booked)
$woDoubleId = $null
Test-Success "Setup: create second work order for double-booking test" {
    $instBody = @{ name = "Multimeter D"; serial_number = "SN-MM-001" } | ConvertTo-Json
    $inst = Invoke-RestMethod -Uri "$base/instruments" -Method Post -Body $instBody -ContentType "application/json"
    $cfgBody = @{ instrument_id = $inst.data.id; cycle_days = 45 } | ConvertTo-Json
    $cfg = Invoke-RestMethod -Uri "$base/configs" -Method Post -Body $cfgBody -ContentType "application/json"
    $woBody = @{ instrument_id = $inst.data.id } | ConvertTo-Json
    $wo = Invoke-RestMethod -Uri "$base/work-orders" -Method Post -Body $woBody -ContentType "application/json"
    $script:woDoubleId = $wo.data.id
}
Test-Fail "Technician double-booking (time overlap)" "WORK_ORDER_CONFLICT" {
    # Same time slot as the already assigned $woReturnId reassign slot (Day 9 9-11am)
    $body = @{
        technician_id = $technicianId
        scheduled_start = (Get-Date).AddDays(9).Date.AddHours(9).ToString("yyyy-MM-ddTHH:mm:ss")
        scheduled_end = (Get-Date).AddDays(9).Date.AddHours(11).ToString("yyyy-MM-ddTHH:mm:ss")
    } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/work-orders/$woDoubleId/assign" -Method Post -Body $body -ContentType "application/json"
}

# F4. Negative cycle days in config
Test-Fail "Negative cycle days" "INVALID_CYCLE_DAYS" {
    $body = @{ instrument_id = $instrumentId; cycle_days = -30 } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/configs" -Method Post -Body $body -ContentType "application/json"
}

# F5. Import negative cycle (JSON import validation)
Test-Fail "Import data with negative cycle" "IMPORT_VALIDATION_FAILED" {
    $importData = @{
        instruments = @(@{ id = "test-imp-1"; name = "Test"; serial_number = "IMP-001" })
        calibration_configs = @(@{ id = "cfg-imp-1"; instrument_id = "test-imp-1"; cycle_days = -10; version = 1 })
        technicians = @()
        technician_schedules = @()
        work_orders = @()
        audit_events = @()
    } | ConvertTo-Json -Depth 10
    Invoke-RestMethod -Uri "$base/data/import" -Method Post -Body $importData -ContentType "application/json"
}

# F6. Duplicate serial number
Test-Fail "Duplicate serial number" "DUPLICATE_SERIAL" {
    $body = @{ name = "Another Gauge"; serial_number = "SN-2026-001" } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/instruments" -Method Post -Body $body -ContentType "application/json"
}

# F7. Delete instrument with open orders
Test-Fail "Delete instrument with open orders" "HAS_OPEN_ORDERS" {
    # use the woReturnId instrument - has assigned order
    $woInstId = (Invoke-RestMethod -Uri "$base/work-orders/$woReturnId" -Method Get).data.instrument_id
    Invoke-RestMethod -Uri "$base/instruments/$woInstId" -Method Delete
}

# F8. Duplicate technician employee_id
Test-Fail "Duplicate employee_id" "DUPLICATE_EMPLOYEE_ID" {
    $body = @{ name = "Duplicate Tech"; employee_id = "EMP-001" } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/technicians" -Method Post -Body $body -ContentType "application/json"
}

# F9. Technician schedule overlap
Test-Fail "Technician schedule overlap" "SCHEDULE_CONFLICT" {
    $body = @{
        start_time = $d7s
        end_time = (Get-Date).AddDays(7).Date.AddHours(10).ToString("yyyy-MM-ddTHH:mm:ss")
    } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/technicians/$technicianId/schedules" -Method Post -Body $body -ContentType "application/json"
}

# F10. Invalid status transition
Test-Fail "Invalid status transition: verify created order" "INVALID_STATUS_TRANSITION" {
    $body = @{ verified_by = "Someone" } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/work-orders/$woNoAssignId/verify" -Method Post -Body $body -ContentType "application/json"
}

Write-Host "`n`n=========================================" -ForegroundColor Cyan
Write-Host " TEST SUMMARY: $pass PASS, $fail FAIL" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
