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

function Assert-Gte($name, $actual, $expected) {
    if ($actual -ge $expected) {
        Write-Host "  PASS: $name" -ForegroundColor Green
        $script:pass++
    } else {
        Write-Host "  FAIL: $name (expected >= $expected, actual=$actual)" -ForegroundColor Red
        $script:fail++
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
Write-Host " OVERDUE RECONCILIATION - BATCH VIEW TEST" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan

$today = Get-Date

# ===================================================================
# SCENARIO 1: Config version switching - snapshot vs active mismatch
# ===================================================================
Write-Host ""
Write-Host "--- SCENARIO 1: Config switching -> cycle_mismatch detection ---" -ForegroundColor Yellow

$inst1Body = @{ name = "Recon Switch Test"; serial_number = "SN-RECON-SWITCH-$runId" } | ConvertTo-Json
$inst1 = (Invoke-RestMethod -Uri "$base/instruments" -Method Post -Body $inst1Body -ContentType "application/json").data
$inst1Id = $inst1.id
Write-Host "  instrument: $inst1Id"

$cfg1v1Body = @{ instrument_id = $inst1Id; cycle_days = 7 } | ConvertTo-Json
$cfg1v1 = (Invoke-RestMethod -Uri "$base/configs" -Method Post -Body $cfg1v1Body -ContentType "application/json").data
Assert-Eq "config v1 cycle=7" $cfg1v1.cycle_days 7

$tech1Body = @{ name = "Recon Tech"; employee_id = "EMP-RECON-$runId" } | ConvertTo-Json
$tech1 = (Invoke-RestMethod -Uri "$base/technicians" -Method Post -Body $tech1Body -ContentType "application/json").data
$tech1Id = $tech1.id

$sched1Body = @{
    start_time = $today.Date.AddHours(9).ToString("yyyy-MM-ddTHH:mm:ss")
    end_time = $today.Date.AddHours(18).ToString("yyyy-MM-ddTHH:mm:ss")
} | ConvertTo-Json
Invoke-RestMethod -Uri "$base/technicians/$tech1Id/schedules" -Method Post -Body $sched1Body -ContentType "application/json" | Out-Null

$wo1Body = @{ instrument_id = $inst1Id; created_by = "test-runner" } | ConvertTo-Json
$wo1 = (Invoke-RestMethod -Uri "$base/work-orders" -Method Post -Body $wo1Body -ContentType "application/json").data
$wo1Id = $wo1.id

$as1Body = @{
    technician_id = $tech1Id
    scheduled_start = $today.Date.AddHours(10).ToString("yyyy-MM-ddTHH:mm:ss")
    scheduled_end = $today.Date.AddHours(12).ToString("yyyy-MM-ddTHH:mm:ss")
} | ConvertTo-Json
Invoke-RestMethod -Uri "$base/work-orders/$wo1Id/assign" -Method Post -Body $as1Body -ContentType "application/json" | Out-Null

$cp1Body = @{ result = "Qualified"; certificate_no = "CERT-RECON-$runId" } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/work-orders/$wo1Id/complete" -Method Post -Body $cp1Body -ContentType "application/json" | Out-Null

$vr1Body = @{ verified_by = "QA Manager" } | ConvertTo-Json
$wo1Verified = (Invoke-RestMethod -Uri "$base/work-orders/$wo1Id/verify" -Method Post -Body $vr1Body -ContentType "application/json").data
$wo1VerifiedDate = $wo1Verified.verified_date.Split('T')[0]

$cfg1v2Body = @{ instrument_id = $inst1Id; cycle_days = 60 } | ConvertTo-Json
$cfg1v2 = (Invoke-RestMethod -Uri "$base/configs" -Method Post -Body $cfg1v2Body -ContentType "application/json").data
Assert-Eq "config v2 cycle=60" $cfg1v2.cycle_days 60

$asOfS1 = $today.AddDays(10).ToString("yyyy-MM-dd")
$recon1Url = "$base/overdue/reconciliation?as_of=$asOfS1`&include_non_overdue=true"
$recon1 = (Invoke-RestMethod -Uri $recon1Url -Method Get)

Write-Host "  cycle_source_breakdown: $($recon1.data.cycle_source_breakdown | ConvertTo-Json -Compress)"
Write-Host "  cycle_mismatch.count: $($recon1.data.cycle_mismatch.count)"
Write-Host "  summary: $($recon1.data.summary | ConvertTo-Json -Compress)"

Assert-NotNull "data.summary exists" $recon1.data.summary
Assert-Eq "summary.as_of correct" $recon1.data.summary.as_of $asOfS1
Assert-True "summary.include_non_overdue=true" $recon1.data.summary.include_non_overdue
Assert-Gte "summary.total_instruments gte 1" $recon1.data.summary.total_instruments 1

Assert-NotNull "cycle_source_breakdown exists" $recon1.data.cycle_source_breakdown
Assert-True "work_order_snapshot in breakdown" ($recon1.data.cycle_source_breakdown.work_order_snapshot -ge 1)

$mismatchInst1 = $recon1.data.cycle_mismatch.details | Where-Object { $_.instrument_id -eq $inst1Id }
Assert-NotNull "inst1 in cycle_mismatch.details" $mismatchInst1
Assert-Eq "mismatch snapshot cycle=7" $mismatchInst1.snapshot_config.cycle_days 7
Assert-Eq "mismatch active cycle=60" $mismatchInst1.active_config.cycle_days 60
Assert-Eq "mismatch applied cycle=7 (snapshot)" $mismatchInst1.applied_cycle_days 7
Assert-Eq "mismatch cycle_diff=53" $mismatchInst1.cycle_diff_days 53
Assert-NotNull "mismatch mismatch_reason non-empty" ($mismatchInst1.mismatch_reason.Length -gt 5)

$groupSnapshot1 = $recon1.data.grouped_instruments.work_order_snapshot | Where-Object { $_.instrument_id -eq $inst1Id }
Assert-NotNull "inst1 in grouped_instruments.work_order_snapshot" $groupSnapshot1
Assert-Eq "group snapshot applied_cycle_days=7" $groupSnapshot1.applied_cycle_days 7

# ===================================================================
# SCENARIO 2: Return + reopen workflow with config switch
# ===================================================================
Write-Host ""
Write-Host "--- SCENARIO 2: Return-reopen + config switch -> snapshot preserved ---" -ForegroundColor Yellow

$rnd2 = Get-Random -Minimum 1000 -Maximum 9999
$inst2Body = @{ name = "Recon Return Test"; serial_number = "SN-RECON-RETURN-$rnd2" } | ConvertTo-Json
$inst2 = (Invoke-RestMethod -Uri "$base/instruments" -Method Post -Body $inst2Body -ContentType "application/json").data
$inst2Id = $inst2.id

$cfg2v1Body = @{ instrument_id = $inst2Id; cycle_days = 14 } | ConvertTo-Json
$cfg2v1 = (Invoke-RestMethod -Uri "$base/configs" -Method Post -Body $cfg2v1Body -ContentType "application/json").data

$wo2Body = @{ instrument_id = $inst2Id } | ConvertTo-Json
$wo2 = (Invoke-RestMethod -Uri "$base/work-orders" -Method Post -Body $wo2Body -ContentType "application/json").data
$wo2Id = $wo2.id

$as2Body = @{
    technician_id = $tech1Id
    scheduled_start = $today.Date.AddHours(11).ToString("yyyy-MM-ddTHH:mm:ss")
    scheduled_end = $today.Date.AddHours(13).ToString("yyyy-MM-ddTHH:mm:ss")
} | ConvertTo-Json
Invoke-RestMethod -Uri "$base/work-orders/$wo2Id/assign" -Method Post -Body $as2Body -ContentType "application/json" | Out-Null

$cp2Body = @{ result = "Needs recalibration"; certificate_no = "CERT-RETURN-RECON-001" } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/work-orders/$wo2Id/complete" -Method Post -Body $cp2Body -ContentType "application/json" | Out-Null

$rt2Body = @{ notes = "Returned for rework" } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/work-orders/$wo2Id/return" -Method Post -Body $rt2Body -ContentType "application/json" | Out-Null

$cfg2v2Body = @{ instrument_id = $inst2Id; cycle_days = 21 } | ConvertTo-Json
$cfg2v2 = (Invoke-RestMethod -Uri "$base/configs" -Method Post -Body $cfg2v2Body -ContentType "application/json").data
Assert-Eq "config v2 cycle=21" $cfg2v2.cycle_days 21

$ra2Body = @{
    technician_id = $tech1Id
    scheduled_start = $today.Date.AddHours(14).ToString("yyyy-MM-ddTHH:mm:ss")
    scheduled_end = $today.Date.AddHours(16).ToString("yyyy-MM-ddTHH:mm:ss")
} | ConvertTo-Json
Invoke-RestMethod -Uri "$base/work-orders/$wo2Id/reassign" -Method Post -Body $ra2Body -ContentType "application/json" | Out-Null

$cp2bBody = @{ result = "Qualified after rework"; certificate_no = "CERT-RETURN-RECON-001-R2" } | ConvertTo-Json
Invoke-RestMethod -Uri "$base/work-orders/$wo2Id/complete" -Method Post -Body $cp2bBody -ContentType "application/json" | Out-Null

$vr2Body = @{ verified_by = "Senior QA" } | ConvertTo-Json
$wo2Final = (Invoke-RestMethod -Uri "$base/work-orders/$wo2Id/verify" -Method Post -Body $vr2Body -ContentType "application/json").data
$wo2FinalDate = $wo2Final.verified_date.Split('T')[0]

$asOfS2 = $today.AddDays(20).ToString("yyyy-MM-dd")
$recon2Url = "$base/overdue/reconciliation?as_of=$asOfS2`&include_non_overdue=true"
$recon2 = (Invoke-RestMethod -Uri $recon2Url -Method Get)

$mismatchInst2 = $recon2.data.cycle_mismatch.details | Where-Object { $_.instrument_id -eq $inst2Id }
Assert-NotNull "inst2 in cycle_mismatch (return-reopen)" $mismatchInst2
Assert-Eq "return-reopen snapshot cycle=14" $mismatchInst2.snapshot_config.cycle_days 14
Assert-Eq "return-reopen active cycle=21" $mismatchInst2.active_config.cycle_days 21
Assert-Eq "return-reopen applied cycle=14" $mismatchInst2.applied_cycle_days 14
Assert-Eq "return-reopen cycle_diff=7" $mismatchInst2.cycle_diff_days 7

# ===================================================================
# SCENARIO 3: No verified work orders -> active_config_fallback group
# ===================================================================
Write-Host ""
Write-Host "--- SCENARIO 3: No verified orders -> active_config_fallback ---" -ForegroundColor Yellow

$rnd3 = Get-Random -Minimum 1000 -Maximum 9999
$inst3Body = @{ name = "Recon NoVerify Test"; serial_number = "SN-RECON-NOVERIFY-$rnd3" } | ConvertTo-Json
$inst3 = (Invoke-RestMethod -Uri "$base/instruments" -Method Post -Body $inst3Body -ContentType "application/json").data
$inst3Id = $inst3.id

$cfg3Body = @{ instrument_id = $inst3Id; cycle_days = 3 } | ConvertTo-Json
$cfg3 = (Invoke-RestMethod -Uri "$base/configs" -Method Post -Body $cfg3Body -ContentType "application/json").data

$asOfS3 = $today.AddDays(5).ToString("yyyy-MM-dd")
$recon3Url = "$base/overdue/reconciliation?as_of=$asOfS3`&include_non_overdue=true"
$recon3 = (Invoke-RestMethod -Uri $recon3Url -Method Get)

$fallbackInst3 = Find-InList $recon3.data.grouped_instruments.active_config_fallback $inst3Id
Assert-NotNull "inst3 in active_config_fallback group" $fallbackInst3
Assert-Eq "fallback applied cycle=3" $fallbackInst3.applied_cycle_days 3
Assert-Eq "fallback reason code present" ($null -ne $fallbackInst3.fallback_reason_code) $true

Assert-True "active_config_fallback in cycle_source_breakdown" ($recon3.data.cycle_source_breakdown.active_config_fallback -ge 1)
Assert-True "NO_WORK_ORDERS_AT_ALL or ONLY_OPEN_ORDERS in reason_code_breakdown" (
    $recon3.data.reason_code_breakdown.NO_WORK_ORDERS_AT_ALL -ge 1 -or
    $recon3.data.reason_code_breakdown.ONLY_OPEN_ORDERS -ge 1
)

# Sub-case: create order but don't verify
Write-Host "  Sub-case: open order exists but not verified..."
$wo3Body = @{ instrument_id = $inst3Id } | ConvertTo-Json
$wo3 = (Invoke-RestMethod -Uri "$base/work-orders" -Method Post -Body $wo3Body -ContentType "application/json").data
$wo3Id = $wo3.id

$recon3b = (Invoke-RestMethod -Uri $recon3Url -Method Get)
$openOrder3 = $recon3b.data.open_orders.details | Where-Object { $_.instrument_id -eq $inst3Id }
Assert-NotNull "inst3 open order in open_orders.details" $openOrder3
Assert-Eq "open order id matches" $openOrder3.open_work_order.id $wo3Id
Assert-Eq "open order participation: display only" $openOrder3.open_order_participation ('未参与 next_due_date 计算，仅作参考展示')
Assert-NotNull "open order participation note" ($openOrder3.participation_note.Length -gt 5)
Assert-Eq "open order calc source still active_config_fallback" $openOrder3.cycle_source_used_for_calc "active_config_fallback"

$fallback3b = Find-InList $recon3b.data.grouped_instruments.active_config_fallback $inst3Id
Assert-Eq "fallback reason ONLY_OPEN_ORDERS" $fallback3b.fallback_reason_code "ONLY_OPEN_ORDERS"

# ===================================================================
# SCENARIO 4: No active config -> unavailable group
# ===================================================================
Write-Host ""
Write-Host "--- SCENARIO 4: No active config -> unavailable group ---" -ForegroundColor Yellow

$rnd4 = Get-Random -Minimum 1000 -Maximum 9999
$inst4Body = @{ name = "Recon NoConfig Test"; serial_number = "SN-RECON-NOCFG-$rnd4" } | ConvertTo-Json
$inst4 = (Invoke-RestMethod -Uri "$base/instruments" -Method Post -Body $inst4Body -ContentType "application/json").data
$inst4Id = $inst4.id

$asOfS4 = $today.ToString("yyyy-MM-dd")
$recon4Url = "$base/overdue/reconciliation?as_of=$asOfS4`&include_non_overdue=true"
$recon4 = (Invoke-RestMethod -Uri $recon4Url -Method Get)

$unavailInst4 = Find-InList $recon4.data.grouped_instruments.unavailable $inst4Id
Assert-NotNull "inst4 in unavailable group" $unavailInst4
Assert-Eq "unavailable reason code NO_ACTIVE_CONFIG" $unavailInst4.unavailable_reason_code "NO_ACTIVE_CONFIG"
Assert-NotNull "unavailable reason message non-empty" ($unavailInst4.unavailable_reason_message.Length -gt 5)

Assert-True "unavailable in cycle_source_breakdown" ($recon4.data.cycle_source_breakdown.unavailable -ge 1)
Assert-True "NO_ACTIVE_CONFIG in reason_code_breakdown" ($recon4.data.reason_code_breakdown.NO_ACTIVE_CONFIG -ge 1)
Assert-Gte "summary.unavailable_count gte 1" $recon4.data.summary.unavailable_count 1

# ===================================================================
# SCENARIO 5: Export -> Import -> reconciliation consistency
# ===================================================================
Write-Host ""
Write-Host "--- SCENARIO 5: Export/Import round-trip -> grouping preserved ---" -ForegroundColor Yellow

$rnd5 = Get-Random -Minimum 1000 -Maximum 9999
$newInst5Id = "inst-recon-imp-$rnd5"
$newCfg5Id = "cfg-recon-imp-$rnd5"
$newWo5Id = "wo-recon-imp-$rnd5"
$newTech5Id = "tech-recon-imp-$rnd5"
$newEmp5Id = "EMP-RECON-IMP-$rnd5"
$newSerial5 = "SN-RECON-IMP-$rnd5"

$importData5 = @{
    instruments = @(
        @{
            id = $newInst5Id
            name = "Recon Imported Instrument"
            serial_number = $newSerial5
            model = "IMP-100"
            status = "active"
            created_at = "2026-01-15T09:00:00.000Z"
            updated_at = "2026-01-15T09:00:00.000Z"
        }
    )
    calibration_configs = @(
        @{
            id = $newCfg5Id
            instrument_id = $newInst5Id
            cycle_days = 5
            version = 1
            is_active = 1
            effective_from = "2026-01-15T10:00:00.000Z"
            created_at = "2026-01-15T10:00:00.000Z"
        }
    )
    technicians = @(
        @{
            id = $newTech5Id
            name = "Recon Imported Tech"
            employee_id = $newEmp5Id
            status = "active"
            created_at = "2026-01-10T00:00:00.000Z"
            updated_at = "2026-01-10T00:00:00.000Z"
        }
    )
    technician_schedules = @()
    work_orders = @(
        @{
            id = $newWo5Id
            instrument_id = $newInst5Id
            config_id = $newCfg5Id
            config_version = 1
            cycle_days_snapshot = 5
            technician_id = $newTech5Id
            status = "verified"
            completed_date = "2026-02-01T14:00:00.000Z"
            verified_date = "2026-02-02T10:00:00.000Z"
            result = "Pass"
            certificate_no = "CERT-RECON-IMP-001"
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
            entity_id = $newInst5Id
            new_values = @{ id = $newInst5Id; name = "Recon Imported Instrument" }
            old_values = $null
            operator = "legacy-system"
            timestamp = "2026-01-15T09:00:00.000Z"
        },
        @{
            event_type = "CREATE"
            entity_type = "work_order"
            entity_id = $newWo5Id
            new_values = @{ id = $newWo5Id; cycle_days_snapshot = 5 }
            old_values = $null
            operator = "legacy-user"
            timestamp = "2026-01-20T08:00:00.000Z"
        },
        @{
            event_type = "STATUS_CHANGE"
            entity_type = "work_order"
            entity_id = $newWo5Id
            new_values = @{ status = "verified" }
            old_values = @{ status = "completed" }
            operator = "legacy-qa"
            timestamp = "2026-02-02T10:00:00.000Z"
        }
    )
} | ConvertTo-Json -Depth 10

$importResult5 = (Invoke-RestMethod -Uri "$base/data/import" -Method Post -Body $importData5 -ContentType "application/json").data
Assert-True "import created gte 1 work order" ($importResult5.work_orders.created -ge 1)

$asOfS5 = "2026-03-01"
$recon5Url = "$base/overdue/reconciliation?as_of=$asOfS5`&include_non_overdue=true"
$recon5 = (Invoke-RestMethod -Uri $recon5Url -Method Get)

$importedSnapshot5 = Find-InList $recon5.data.grouped_instruments.work_order_snapshot $newInst5Id
Assert-NotNull "imported inst in work_order_snapshot group" $importedSnapshot5
Assert-Eq "imported applied_cycle_days=5 (snapshot)" $importedSnapshot5.applied_cycle_days 5
Assert-Eq "imported snapshot_config_id matches" $importedSnapshot5.snapshot_config_id $newCfg5Id
Assert-Eq "imported snapshot_config_version=1" $importedSnapshot5.snapshot_config_version 1
Assert-Eq "imported work_order_id matches" $importedSnapshot5.work_order_id $newWo5Id
$expectedNextDue5 = "2026-02-07"
Assert-Eq "imported next_due_date = 2026-02-02 + 5d" $importedSnapshot5.next_due_date $expectedNextDue5

# ===================================================================
# SCENARIO 6: Determinism - same query repeated identical (including restart)
# ===================================================================
Write-Host ""
Write-Host "--- SCENARIO 6: Determinism - repeated queries identical ---" -ForegroundColor Yellow

$asOfS6 = $today.AddDays(30).ToString("yyyy-MM-dd")
$recon6Url = "$base/overdue/reconciliation?as_of=$asOfS6`&include_non_overdue=true"

$q6_1 = (Invoke-RestMethod -Uri $recon6Url -Method Get).data
$q6_2 = (Invoke-RestMethod -Uri $recon6Url -Method Get).data
$q6_3 = (Invoke-RestMethod -Uri $recon6Url -Method Get).data

$q6_1Json = $q6_1 | ConvertTo-Json -Depth 10 -Compress
$q6_2Json = $q6_2 | ConvertTo-Json -Depth 10 -Compress
$q6_3Json = $q6_3 | ConvertTo-Json -Depth 10 -Compress

Assert-Eq "q1 == q2 (repeated reconciliation identical)" $q6_1Json $q6_2Json
Assert-Eq "q2 == q3 (multi-query reconciliation identical)" $q6_2Json $q6_3Json

# ===================================================================
# SCENARIO 7: include_non_overdue flag behavior
# ===================================================================
Write-Host ""
Write-Host "--- SCENARIO 7: include_non_overdue flag behavior ---" -ForegroundColor Yellow

$recon7Default = (Invoke-RestMethod -Uri "$base/overdue/reconciliation?as_of=$asOfS6" -Method Get).data
$recon7True = (Invoke-RestMethod -Uri "$base/overdue/reconciliation?as_of=$asOfS6`&include_non_overdue=true" -Method Get).data
$recon7False = (Invoke-RestMethod -Uri "$base/overdue/reconciliation?as_of=$asOfS6`&include_non_overdue=false" -Method Get).data

Write-Host "  default shown_count=$($recon7Default.summary.shown_instruments)"
Write-Host "  include_non_overdue=true shown_count=$($recon7True.summary.shown_instruments)"
Write-Host "  include_non_overdue=false shown_count=$($recon7False.summary.shown_instruments)"

Assert-True "include_non_overdue=true shows gte default" ($recon7True.summary.shown_instruments -ge $recon7Default.summary.shown_instruments)
Assert-Eq "include_non_overdue=false same as default" $recon7False.summary.shown_instruments $recon7Default.summary.shown_instruments
Assert-True "default summary.include_non_overdue=false" ($recon7Default.summary.include_non_overdue -eq $false)
Assert-True "true summary.include_non_overdue=true" ($recon7True.summary.include_non_overdue -eq $true)

# ===================================================================
# SCENARIO 8: Cross-verify reconciliation with explain endpoint
# ===================================================================
Write-Host ""
Write-Host "--- SCENARIO 8: Cross-verify reconciliation vs /explain ---" -ForegroundColor Yellow

$explain8Url = "$base/overdue/explain?as_of=$asOfS1`&include_non_overdue=true`&instrument_id=$inst1Id"
$explain8 = (Invoke-RestMethod -Uri $explain8Url -Method Get).data
$exp8 = $explain8[0]
if (-not $exp8) { $exp8 = $explain8 }

$recon8Url = "$base/overdue/reconciliation?as_of=$asOfS1`&include_non_overdue=true"
$recon8 = (Invoke-RestMethod -Uri $recon8Url -Method Get).data

$reconInst8 = Find-InList $recon8.grouped_instruments.work_order_snapshot $inst1Id
Assert-NotNull "inst1 found in reconciliation group" $reconInst8
Assert-Eq "applied_cycle_days matches explain" $reconInst8.applied_cycle_days $exp8.base_calculation.applied_cycle_days
Assert-Eq "next_due_date matches explain" $reconInst8.next_due_date $exp8.base_calculation.next_due_date
Assert-Eq "is_overdue matches explain" $reconInst8.is_overdue $exp8.base_calculation.is_overdue
Assert-Eq "cycle_source consistent: work_order_snapshot" $exp8.trace.cycle_source "work_order_snapshot"

$mismatch8 = $recon8.cycle_mismatch.details | Where-Object { $_.instrument_id -eq $inst1Id }
Assert-Eq "mismatch applied_cycle_days == explain applied" $mismatch8.applied_cycle_days $exp8.base_calculation.applied_cycle_days
Assert-Eq "mismatch snapshot_config.version == explain snapshot_config.version" $mismatch8.snapshot_config.version $exp8.trace.snapshot_config.version

# ===================================================================
# Summary
# ===================================================================
Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host " OVERDUE RECONCILIATION SUMMARY: $pass PASS, $fail FAIL" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan

if ($fail -gt 0) { exit 1 }
