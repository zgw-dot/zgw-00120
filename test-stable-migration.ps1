$base = "http://localhost:3000/api"
$pass = 0
$fail = 0
$runId = [System.Guid]::NewGuid().ToString().Substring(0, 8)

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

function Assert-Equal($actual, $expected, $msg) {
    if ($actual -ne $expected) {
        throw "$msg : expected=$expected, actual=$actual"
    }
}

function Assert-NotNull($obj, $msg) {
    if ($null -eq $obj) {
        throw "$msg : expected non-null but got null"
    }
}

function New-UniqueId($prefix) {
    return "$prefix-$runId-$(Get-Random -Maximum 10000)"
}

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Stable Migration Package Test Suite" -ForegroundColor Cyan
Write-Host " Run ID: $runId" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

# ============================================================
# SCENARIO 1: Setup test data
# ============================================================
Write-Host "`n--- SC1: Setup test data ---" -ForegroundColor Cyan

$instId = $null
$cfgId = $null
$techId = $null
$woId = $null

Test-Success "Create instrument" {
    $body = @{
        name = "Stable Test Instrument"
        serial_number = "SN-STABLE-$runId"
        model = "STB-100"
        location = "Lab Stable"
    } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "$base/instruments" -Method Post -Body $body -ContentType "application/json"
    $script:instId = $r.data.id
    Write-Host "  instrument_id: $instId"
}

Test-Success "Create calibration config" {
    $body = @{
        instrument_id = $instId
        cycle_days = 30
        tolerance = "+/-1%"
        standard = "ISO-9001"
    } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "$base/configs" -Method Post -Body $body -ContentType "application/json"
    $script:cfgId = $r.data.id
    Write-Host "  config_id: $cfgId, version: $($r.data.version)"
}

Test-Success "Create technician" {
    $body = @{
        name = "Stable Tech"
        employee_id = "EMP-STABLE-$runId"
        title = "Senior Engineer"
    } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "$base/technicians" -Method Post -Body $body -ContentType "application/json"
    $script:techId = $r.data.id
    Write-Host "  technician_id: $techId"
}

Test-Success "Add technician schedule" {
    $body = @{
        start_time = "2026-07-01T09:00:00"
        end_time = "2026-07-01T17:00:00"
        shift_type = "regular"
    } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "$base/technicians/$techId/schedules" -Method Post -Body $body -ContentType "application/json"
    Write-Host "  schedule_id: $($r.data.id)"
}

Test-Success "Create work order" {
    $body = @{
        instrument_id = $instId
        planned_date = "2026-07-01"
        created_by = "stable_test"
    } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "$base/work-orders" -Method Post -Body $body -ContentType "application/json"
    $script:woId = $r.data.id
    Write-Host "  work_order_id: $woId"
}

Test-Success "Assign and complete and verify work order" {
    $assignBody = @{
        technician_id = $techId
        scheduled_start = "2026-07-01T10:00:00"
        scheduled_end = "2026-07-01T12:00:00"
    } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/work-orders/$woId/assign" -Method Post -Body $assignBody -ContentType "application/json" | Out-Null

    $completeBody = @{
        result = "Pass"
        certificate_no = "CERT-STABLE-$runId"
        deviation = "0"
    } | ConvertTo-Json
    Invoke-RestMethod -Uri "$base/work-orders/$woId/complete" -Method Post -Body $completeBody -ContentType "application/json" | Out-Null

    $verifyBody = @{ verified_by = "Stable QA" } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "$base/work-orders/$woId/verify" -Method Post -Body $verifyBody -ContentType "application/json"
    Write-Host "  status: $($r.data.status)"
}

# ============================================================
# SCENARIO 2: Stable export - multiple calls consistent
# ============================================================
Write-Host "`n--- SC2: Stable export consistency ---" -ForegroundColor Cyan

$export1Hash = $null
$export2Hash = $null

Test-Success "First stable export" {
    $r = Invoke-RestMethod -Uri "$base/data/export?stable=true" -Method Get
    $script:export1Hash = $r.data.manifest.content_hash
    Write-Host "  instruments: $($r.data.instruments.Count)"
    Write-Host "  content_hash: $($export1Hash.Substring(0, 16))..."
    Assert-NotNull $r.data.manifest "manifest should exist"
    Assert-NotNull $r.data.manifest.content_hash "content_hash should exist"
    Assert-Equal $r.data.manifest.export_mode "stable" "export_mode should be stable"
}

Test-Success "Second stable export (same hash)" {
    $r = Invoke-RestMethod -Uri "$base/data/export?stable=true" -Method Get
    $script:export2Hash = $r.data.manifest.content_hash
    Assert-Equal $r.data.manifest.content_hash $export1Hash "content_hash should match between consecutive exports"
    Write-Host "  hash matches: OK"
}

# ============================================================
# SCENARIO 3: Full response round-trip import (data wrapper)
# ============================================================
Write-Host "`n--- SC3: Full response round-trip import ---" -ForegroundColor Cyan

$newInstId = New-UniqueId "imp-inst"
$newCfgId = New-UniqueId "imp-cfg"
$newTechId = New-UniqueId "imp-tech"

Test-Success "Import full response format (with data wrapper)" {
    $pkgObj = @{
        data = @{
            instruments = @(
                @{
                    id = $newInstId
                    name = "Import Roundtrip Test"
                    serial_number = "SN-RT-$runId"
                    model = "RT-100"
                    location = "Import Lab"
                    status = "active"
                    created_at = "2026-01-01T00:00:00.000Z"
                    updated_at = "2026-01-01T00:00:00.000Z"
                }
            )
            calibration_configs = @(
                @{
                    id = $newCfgId
                    instrument_id = $newInstId
                    cycle_days = 60
                    version = 1
                    is_active = 1
                    tolerance = ""
                    standard = ""
                    effective_from = "2026-01-01T00:00:00.000Z"
                    created_at = "2026-01-01T00:00:00.000Z"
                }
            )
            technicians = @(
                @{
                    id = $newTechId
                    name = "Import RT Tech"
                    employee_id = "EMP-RT-$runId"
                    status = "active"
                    title = ""
                    phone = ""
                    email = ""
                    created_at = "2026-01-01T00:00:00.000Z"
                    updated_at = "2026-01-01T00:00:00.000Z"
                }
            )
            technician_schedules = @()
            work_orders = @()
            audit_events = @()
        }
    }
    $pkg = $pkgObj | ConvertTo-Json -Depth 10

    $r = Invoke-RestMethod -Uri "$base/data/import" -Method Post -Body $pkg -ContentType "application/json"
    Write-Host "  import_mode: $($r.data.import_mode)"
    Write-Host "  wrapper_format: $($r.data.wrapper_format)"
    Write-Host "  instruments created: $($r.data.instruments.created)"
    Write-Host "  instruments skipped: $($r.data.instruments.skipped)"
    Assert-Equal $r.data.wrapper_format "full_response" "wrapper should be full_response"
    Assert-Equal $r.data.instruments.created 1 "should create 1 instrument"
    Assert-Equal $r.data.calibration_configs.created 1 "should create 1 config"
    Assert-Equal $r.data.technicians.created 1 "should create 1 technician"
}

# ============================================================
# SCENARIO 4: Duplicate import - IDs should be skipped
# ============================================================
Write-Host "`n--- SC4: Duplicate import (conflict skip) ---" -ForegroundColor Cyan

Test-Success "Import again - all should be skipped" {
    $pkgObj = @{
        data = @{
            instruments = @(
                @{
                    id = $newInstId
                    name = "Duplicate Import Test"
                    serial_number = "SN-RT-$runId"
                    model = "RT-200"
                    location = "Duplicate Lab"
                    status = "active"
                    created_at = "2026-01-01T00:00:00.000Z"
                    updated_at = "2026-01-01T00:00:00.000Z"
                }
            )
            calibration_configs = @(
                @{
                    id = $newCfgId
                    instrument_id = $newInstId
                    cycle_days = 90
                    version = 1
                    is_active = 1
                    tolerance = ""
                    standard = ""
                    effective_from = "2026-01-01T00:00:00.000Z"
                    created_at = "2026-01-01T00:00:00.000Z"
                }
            )
            technicians = @(
                @{
                    id = $newTechId
                    name = "Duplicate RT Tech"
                    employee_id = "EMP-RT-$runId"
                    status = "active"
                    title = ""
                    phone = ""
                    email = ""
                    created_at = "2026-01-01T00:00:00.000Z"
                    updated_at = "2026-01-01T00:00:00.000Z"
                }
            )
            technician_schedules = @()
            work_orders = @()
            audit_events = @()
        }
    }
    $pkg = $pkgObj | ConvertTo-Json -Depth 10

    $r = Invoke-RestMethod -Uri "$base/data/import" -Method Post -Body $pkg -ContentType "application/json"
    Write-Host "  instruments skipped: $($r.data.instruments.skipped)"
    Write-Host "  instruments skipped_ids: $($r.data.instruments.skipped_ids -join ', ')"
    Write-Host "  configs skipped: $($r.data.calibration_configs.skipped)"
    Write-Host "  techs skipped: $($r.data.technicians.skipped)"
    Assert-Equal $r.data.instruments.skipped 1 "should skip 1 instrument"
    Assert-Equal $r.data.instruments.skipped_ids[0] $newInstId "skipped id should match"
    Assert-Equal $r.data.calibration_configs.skipped 1 "should skip 1 config"
    Assert-Equal $r.data.technicians.skipped 1 "should skip 1 tech"
}

Test-Success "Verify data NOT overwritten (original values preserved)" {
    $r = Invoke-RestMethod -Uri "$base/instruments/$newInstId" -Method Get
    Write-Host "  instrument name: $($r.data.name)"
    Write-Host "  instrument model: $($r.data.model)"
    Assert-Equal $r.data.name "Import Roundtrip Test" "name should NOT be overwritten"
    Assert-Equal $r.data.model "RT-100" "model should NOT be overwritten"
}

# ============================================================
# SCENARIO 5: Negative cycle days - entire package rejected
# ============================================================
Write-Host "`n--- SC5: Negative cycle rejection (entire package rejected) ---" -ForegroundColor Cyan

$negInstId = New-UniqueId "neg-inst"

Test-Fail "Import with negative cycle_days" "IMPORT_VALIDATION_FAILED" {
    $pkgObj = @{
        instruments = @(
            @{
                id = $negInstId
                name = "Negative Test"
                serial_number = "SN-NEG-$runId"
                created_at = "2026-01-01T00:00:00.000Z"
                updated_at = "2026-01-01T00:00:00.000Z"
            }
        )
        calibration_configs = @(
            @{
                id = (New-UniqueId "neg-cfg")
                instrument_id = $negInstId
                cycle_days = -5
                version = 1
                effective_from = "2026-01-01T00:00:00.000Z"
                created_at = "2026-01-01T00:00:00.000Z"
            }
        )
        technicians = @()
        technician_schedules = @()
        work_orders = @()
        audit_events = @()
    }
    $pkg = $pkgObj | ConvertTo-Json -Depth 10
    Invoke-RestMethod -Uri "$base/data/import" -Method Post -Body $pkg -ContentType "application/json"
}

Test-Success "Verify instrument NOT created (no partial import)" {
    try {
        $r = Invoke-RestMethod -Uri "$base/instruments/$negInstId" -Method Get
        throw "Instrument should NOT exist after validation failure"
    } catch {
        if ($_.Exception.Response.StatusCode.value__ -eq 404) {
            Write-Host "  instrument not found (correct - entire package rejected)"
        } else {
            throw $_.Exception
        }
    }
}

# ============================================================
# SCENARIO 6: Direct format import (without data wrapper)
# ============================================================
Write-Host "`n--- SC6: Direct format import (legacy, no data wrapper) ---" -ForegroundColor Cyan

$directInstId = New-UniqueId "direct-inst"

Test-Success "Import direct format (old style)" {
    $pkgObj = @{
        instruments = @(
            @{
                id = $directInstId
                name = "Direct Format Test"
                serial_number = "SN-DIRECT-$runId"
                model = "DIR-100"
                status = "active"
                created_at = "2026-01-01T00:00:00.000Z"
                updated_at = "2026-01-01T00:00:00.000Z"
            }
        )
        calibration_configs = @()
        technicians = @()
        technician_schedules = @()
        work_orders = @()
        audit_events = @()
    }
    $pkg = $pkgObj | ConvertTo-Json -Depth 10

    $r = Invoke-RestMethod -Uri "$base/data/import" -Method Post -Body $pkg -ContentType "application/json"
    Write-Host "  wrapper_format: $($r.data.wrapper_format)"
    Write-Host "  instruments created: $($r.data.instruments.created)"
    Assert-Equal $r.data.wrapper_format "direct" "wrapper should be direct"
    Assert-Equal $r.data.instruments.created 1 "should create 1 instrument"
}

# ============================================================
# SCENARIO 7: Stable package with manifest - hash verification (raw JSON)
# ============================================================
Write-Host "`n--- SC7: Stable package hash verification (raw JSON round-trip) ---" -ForegroundColor Cyan

Test-Success "Export and re-import stable package - hash should match" {
    $webClient = New-Object System.Net.WebClient

    $rawBytes = $webClient.DownloadData("$base/data/export?stable=true")
    Write-Host "  export size: $($rawBytes.Length) bytes"

    $webClient.Headers.Add("Content-Type", "application/json")
    $importRespBytes = $webClient.UploadData("$base/data/import", "POST", $rawBytes)
    $importRespStr = [System.Text.Encoding]::UTF8.GetString($importRespBytes)
    $importResult = $importRespStr | ConvertFrom-Json

    Write-Host "  import_mode: $($importResult.data.import_mode)"
    Write-Host "  wrapper_format: $($importResult.data.wrapper_format)"
    Write-Host "  hash verified: $($importResult.data.hash_verification.verified)"
    Write-Host "  hash reason: $($importResult.data.hash_verification.reason)"

    Assert-Equal $importResult.data.import_mode "stable_package" "should be stable_package"
    Assert-Equal $importResult.data.wrapper_format "full_response" "wrapper should be full_response"
    Assert-Equal $importResult.data.hash_verification.verified $true "hash should verify"
    Assert-Equal $importResult.data.hash_verification.reason "MATCH" "hash reason should be MATCH"

    $webClient.Dispose()
}

# ============================================================
# SCENARIO 8: Audit traceability - IMPORT, ENTITY_IMPORT, conflicts
# ============================================================
Write-Host "`n--- SC8: Audit traceability ---" -ForegroundColor Cyan

Test-Success "Query IMPORT audit events" {
    $r = Invoke-RestMethod -Uri "$base/audit?event_type=IMPORT&limit=5" -Method Get
    Write-Host "  IMPORT events found: $($r.data.Count)"
    if ($r.data.Count -gt 0) {
        $latest = $r.data[$r.data.Count - 1]
        Write-Host "  latest IMPORT event id: $($latest.id)"
    }
    Assert-NotNull $r.data "audit events should exist"
}

Test-Success "Query ENTITY_IMPORT audit events" {
    $r = Invoke-RestMethod -Uri "$base/audit?event_type=ENTITY_IMPORT&limit=20" -Method Get
    Write-Host "  ENTITY_IMPORT events found: $($r.data.Count)"
    if ($r.data.Count -gt 0) {
        $latest = $r.data[$r.data.Count - 1]
        if ($latest.new_values) {
            $status = $latest.new_values.import_status
            Write-Host "  latest entity: $($latest.entity_type)/$($latest.entity_id), status: $status"
        }
    }
    Assert-NotNull $r.data "ENTITY_IMPORT events should exist"
}

Test-Success "Query IMPORT_VALIDATION_FAILED audit events" {
    $r = Invoke-RestMethod -Uri "$base/audit?event_type=IMPORT_VALIDATION_FAILED&limit=5" -Method Get
    Write-Host "  IMPORT_VALIDATION_FAILED events found: $($r.data.Count)"
    Assert-NotNull $r.data "validation failure audit events should exist"
    if ($r.data.Count -gt 0) {
        $latest = $r.data[$r.data.Count - 1]
        if ($latest.new_values) {
            $sev = $latest.new_values.severity
            $reason = $latest.new_values.rejection_reason
            Write-Host "  severity: $sev"
            Write-Host "  rejection_reason: $reason"
        }
    }
}

Test-Success "Verify ENTITY_IMPORT has import_status for created and skipped" {
    $r = Invoke-RestMethod -Uri "$base/audit/entity/instrument/$newInstId" -Method Get
    $entityImports = $r.data | Where-Object { $_.event_type -eq 'ENTITY_IMPORT' }
    Write-Host "  ENTITY_IMPORT events for $newInstId : $($entityImports.Count)"

    $foundCreated = $false
    $foundSkipped = $false

    foreach ($ev in $entityImports) {
        if ($ev.new_values -and $ev.new_values.import_status) {
            $status = $ev.new_values.import_status
            if ($status -eq 'created') { $foundCreated = $true }
            if ($status -eq 'skipped_id_conflict') { $foundSkipped = $true }
        }
    }

    Write-Host "  found created status: $foundCreated"
    Write-Host "  found skipped_id_conflict status: $foundSkipped"
    Assert-Equal $foundCreated $true "should have ENTITY_IMPORT with created status"
    Assert-Equal $foundSkipped $true "should have ENTITY_IMPORT with skipped_id_conflict status"
}

# ============================================================
# SCENARIO 9: Overdue explain/reconciliation traceability after import
# ============================================================
Write-Host "`n--- SC9: Overdue explain/reconciliation after import ---" -ForegroundColor Cyan

Test-Success "Query overdue explain for imported instrument" {
    $uri = "$base/overdue/explain/$newInstId`?as_of=2026-08-01"
    $r = Invoke-RestMethod -Uri $uri -Method Get
    Write-Host "  instrument: $($r.data.instrument_name)"
    Write-Host "  cycle_source: $($r.data.trace.cycle_source)"
    Write-Host "  is_imported: $($r.data.trace.import_info.is_imported)"
    Write-Host "  evidence: $($r.data.trace.import_info.evidence)"
    Assert-Equal $r.data.trace.import_info.is_imported $true "imported instrument should show as imported"
    Assert-NotNull $r.data.trace.import_info.related_audit_id "should have related audit id"
}

Test-Success "Query overdue reconciliation" {
    $uri = "$base/overdue/reconciliation`?as_of=2026-08-01&include_non_overdue=true"
    $r = Invoke-RestMethod -Uri $uri -Method Get
    Write-Host "  total instruments: $($r.data.summary.total_instruments)"
    Write-Host "  overdue: $($r.data.summary.overdue_count)"
    Write-Host "  cycle_source_breakdown keys: $($r.data.cycle_source_breakdown.PSObject.Properties.Name -join ', ')"
    Assert-NotNull $r.data.summary "summary should exist"
    Assert-NotNull $r.data.grouped_instruments "grouped instruments should exist"
}

# ============================================================
# SCENARIO 10: Deterministic / repeat export consistency
# ============================================================
Write-Host "`n--- SC10: Deterministic export (3 calls) ---" -ForegroundColor Cyan

Test-Success "Three consecutive stable exports - all hashes match" {
    $e1 = (Invoke-RestMethod -Uri "$base/data/export?stable=true" -Method Get).data.manifest.content_hash
    Start-Sleep -Milliseconds 500
    $e2 = (Invoke-RestMethod -Uri "$base/data/export?stable=true" -Method Get).data.manifest.content_hash
    Start-Sleep -Milliseconds 500
    $e3 = (Invoke-RestMethod -Uri "$base/data/export?stable=true" -Method Get).data.manifest.content_hash

    Write-Host "  hash1: $($e1.Substring(0, 16))..."
    Write-Host "  hash2: $($e2.Substring(0, 16))..."
    Write-Host "  hash3: $($e3.Substring(0, 16))..."

    Assert-Equal $e1 $e2 "hash1 should equal hash2"
    Assert-Equal $e2 $e3 "hash2 should equal hash3"
    Write-Host "  All three hashes match: OK"
}

# ============================================================
# SCENARIO 11: Cross-restart consistency (manual verification)
# ============================================================
Write-Host "`n--- SC11: Cross-restart consistency check ---" -ForegroundColor Cyan

if ($env:RUN_SCENARIO_11 -eq '1') {
    Test-Success "Verify hash matches pre-restart hash" {
        $currentHash = (Invoke-RestMethod -Uri "$base/data/export?stable=true" -Method Get).data.manifest.content_hash
        Write-Host "  current hash: $($currentHash.Substring(0, 16))..."

        if ($env:PRE_RESTART_HASH) {
            Write-Host "  pre-restart hash: $($env:PRE_RESTART_HASH.Substring(0, 16))..."
            Assert-Equal $currentHash $env:PRE_RESTART_HASH "hash should match after restart"
            Write-Host "  Hash matches after restart: OK"
        } else {
            Write-Host "  No PRE_RESTART_HASH set. Run with:"
            Write-Host "    `$env:RUN_SCENARIO_11='1'; `$env:PRE_RESTART_HASH='<hash>'"
            Write-Host "  Skipping assertion."
        }
    }
} else {
    Write-Host "  Skipping SC11 (cross-restart). To run:" -ForegroundColor Gray
    Write-Host "    1. Run this script and note the hash"
    Write-Host "    2. Restart the server"
    Write-Host "    3. Run: `$env:RUN_SCENARIO_11='1'; `$env:PRE_RESTART_HASH='<hash>'; .\test-stable-migration.ps1"
}

# ============================================================
# Summary
# ============================================================
Write-Host "`n`n=========================================" -ForegroundColor Cyan
Write-Host " TEST SUMMARY: $pass PASS, $fail FAIL" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan

if ($fail -gt 0) {
    exit 1
}


