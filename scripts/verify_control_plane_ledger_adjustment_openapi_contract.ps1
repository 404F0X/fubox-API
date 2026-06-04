param(
  [string]$OpenApiPath = "examples/openapi_admin_skeleton.yaml"
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
if (-not [System.IO.Path]::IsPathRooted($OpenApiPath)) {
  $OpenApiPath = Join-Path $repoRoot $OpenApiPath
}
$OpenApiPath = (Resolve-Path $OpenApiPath).Path

$script:Failures = New-Object System.Collections.Generic.List[string]

function Add-Failure {
  param([Parameter(Mandatory = $true)][string]$Message)

  [void]$script:Failures.Add($Message)
  Write-Host $Message
}

function Check {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][scriptblock]$Action
  )

  try {
    & $Action
    Write-Host "[OK] $Name"
  } catch {
    Add-Failure "[FAIL] $Name - $($_.Exception.Message)"
  }
}

function Normalize-YamlToken {
  param([AllowNull()][string]$Value)

  if ($null -eq $Value) {
    return ""
  }

  $trimmed = $Value.Trim()
  if ($trimmed.Length -ge 2) {
    $first = $trimmed.Substring(0, 1)
    $last = $trimmed.Substring($trimmed.Length - 1, 1)
    if (($first -eq "'" -and $last -eq "'") -or ($first -eq '"' -and $last -eq '"')) {
      return $trimmed.Substring(1, $trimmed.Length - 2)
    }
  }

  return $trimmed
}

function Join-OpenApiPath {
  param(
    [AllowNull()][string]$Parent,
    [Parameter(Mandatory = $true)][string]$Key
  )

  if ([string]::IsNullOrEmpty($Parent)) {
    return $Key
  }

  return "$Parent>$Key"
}

function New-OpenApiPath {
  param([Parameter(Mandatory = $true)][string[]]$Parts)

  return ($Parts -join ">")
}

function Read-OpenApiYamlSubset {
  param([Parameter(Mandatory = $true)][string]$Path)

  $entries = New-Object System.Collections.Generic.List[object]
  $sequenceItems = New-Object System.Collections.Generic.List[object]
  $stack = New-Object System.Collections.Generic.List[object]
  [void]$stack.Add([pscustomobject]@{ Indent = -1; Path = "" })

  $lineNumber = 0
  foreach ($line in Get-Content -Path $Path) {
    $lineNumber += 1
    if ([string]::IsNullOrWhiteSpace($line)) {
      continue
    }

    $trimmedStart = $line.TrimStart()
    if ($trimmedStart.StartsWith("#")) {
      continue
    }

    if ($line -match "^\s*\t") {
      throw "line $lineNumber uses tab indentation"
    }

    $indent = ([regex]::Match($line, "^( *)")).Groups[1].Value.Length
    if (($indent % 2) -ne 0) {
      throw "line $lineNumber uses non-2-space indentation"
    }

    while ($stack.Count -gt 0 -and $stack[$stack.Count - 1].Indent -ge $indent) {
      $stack.RemoveAt($stack.Count - 1)
    }
    if ($stack.Count -eq 0) {
      throw "line $lineNumber has no parse parent"
    }

    $parentPath = [string]$stack[$stack.Count - 1].Path
    $content = $line.Substring($indent)

    if ($content.StartsWith("- ")) {
      $item = $content.Substring(2).Trim()
      if ($item -match "^([^:]+):(?:\s*(.*))?$") {
        $key = Normalize-YamlToken $Matches[1]
        $value = Normalize-YamlToken $Matches[2]
        $path = Join-OpenApiPath $parentPath $key
        [void]$entries.Add([pscustomobject]@{
            Path       = $path
            ParentPath = $parentPath
            Key        = $key
            Value      = $value
            Line       = $lineNumber
            Indent     = $indent
          })
        if ([string]::IsNullOrEmpty($value)) {
          [void]$stack.Add([pscustomobject]@{ Indent = $indent; Path = $path })
        }
      } else {
        [void]$sequenceItems.Add([pscustomobject]@{
            ParentPath = $parentPath
            Value      = Normalize-YamlToken $item
            Line       = $lineNumber
          })
      }
      continue
    }

    if (-not ($content -match "^([^:]+):(?:\s*(.*))?$")) {
      throw "line $lineNumber is outside the supported OpenAPI YAML subset"
    }

    $key = Normalize-YamlToken $Matches[1]
    $value = Normalize-YamlToken $Matches[2]
    $currentPath = Join-OpenApiPath $parentPath $key
    [void]$entries.Add([pscustomobject]@{
        Path       = $currentPath
        ParentPath = $parentPath
        Key        = $key
        Value      = $value
        Line       = $lineNumber
        Indent     = $indent
      })
    if ([string]::IsNullOrEmpty($value)) {
      [void]$stack.Add([pscustomobject]@{ Indent = $indent; Path = $currentPath })
    }
  }

  return [pscustomobject]@{
    Entries       = @($entries.ToArray())
    SequenceItems = @($sequenceItems.ToArray())
  }
}

function Get-OpenApiValues {
  param(
    [Parameter(Mandatory = $true)]$Spec,
    [Parameter(Mandatory = $true)][string]$Path
  )

  return @($Spec.Entries | Where-Object { $_.Path -eq $Path } | ForEach-Object { $_.Value })
}

function Get-OpenApiListValues {
  param(
    [Parameter(Mandatory = $true)]$Spec,
    [Parameter(Mandatory = $true)][string]$Path
  )

  $values = New-Object System.Collections.Generic.List[string]
  foreach ($entry in @($Spec.Entries | Where-Object { $_.Path -eq $Path })) {
    $value = [string]$entry.Value
    if ($value.StartsWith("[") -and $value.EndsWith("]")) {
      $inner = $value.Substring(1, $value.Length - 2)
      foreach ($part in ($inner -split ",")) {
        $normalized = Normalize-YamlToken $part
        if (-not [string]::IsNullOrWhiteSpace($normalized)) {
          [void]$values.Add($normalized)
        }
      }
    }
  }
  foreach ($item in @($Spec.SequenceItems | Where-Object { $_.ParentPath -eq $Path })) {
    [void]$values.Add([string]$item.Value)
  }

  return @($values.ToArray())
}

function Assert-PathExists {
  param(
    [Parameter(Mandatory = $true)]$Spec,
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Message
  )

  if (@($Spec.Entries | Where-Object { $_.Path -eq $Path }).Count -eq 0) {
    throw "${Message}: missing path $Path"
  }
}

function Assert-PathValue {
  param(
    [Parameter(Mandatory = $true)]$Spec,
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Expected,
    [Parameter(Mandatory = $true)][string]$Message
  )

  $values = @(Get-OpenApiValues -Spec $Spec -Path $Path)
  if ($values -notcontains $Expected) {
    throw "${Message}: expected '$Expected' at $Path, got '$($values -join ", ")'"
  }
}

function Assert-ListContains {
  param(
    [Parameter(Mandatory = $true)]$Spec,
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string[]]$Expected,
    [Parameter(Mandatory = $true)][string]$Message
  )

  $values = @(Get-OpenApiListValues -Spec $Spec -Path $Path)
  foreach ($expectedValue in $Expected) {
    if ($values -notcontains $expectedValue) {
      throw "${Message}: expected '$expectedValue' in $Path, got '$($values -join ", ")'"
    }
  }
}

function Assert-Ref {
  param(
    [Parameter(Mandatory = $true)]$Spec,
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$ExpectedRef,
    [Parameter(Mandatory = $true)][string]$Message
  )

  Assert-PathValue -Spec $Spec -Path (Join-OpenApiPath $Path '$ref') -Expected $ExpectedRef -Message $Message
}

function Assert-PropertyRef {
  param(
    [Parameter(Mandatory = $true)]$Spec,
    [Parameter(Mandatory = $true)][string]$SchemaPath,
    [Parameter(Mandatory = $true)][string]$Property,
    [Parameter(Mandatory = $true)][string]$ExpectedRef,
    [Parameter(Mandatory = $true)][string]$Message
  )

  Assert-Ref -Spec $Spec -Path (New-OpenApiPath @($SchemaPath, "properties", $Property)) -ExpectedRef $ExpectedRef -Message $Message
}

function Assert-ConstFalse {
  param(
    [Parameter(Mandatory = $true)]$Spec,
    [Parameter(Mandatory = $true)][string]$PropertyPath,
    [Parameter(Mandatory = $true)][string]$Message
  )

  Assert-PathValue -Spec $Spec -Path (Join-OpenApiPath $PropertyPath "const") -Expected "false" -Message $Message
}

function Assert-EnumOmitted {
  param(
    [Parameter(Mandatory = $true)]$Spec,
    [Parameter(Mandatory = $true)][string]$PropertyPath,
    [Parameter(Mandatory = $true)][string]$Message
  )

  Assert-ListContains -Spec $Spec -Path (Join-OpenApiPath $PropertyPath "enum") -Expected @("omitted") -Message $Message
}

function Assert-ScalarContains {
  param(
    [Parameter(Mandatory = $true)]$Spec,
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string[]]$Needles,
    [Parameter(Mandatory = $true)][string]$Message
  )

  $text = (Get-OpenApiValues -Spec $Spec -Path $Path) -join " "
  foreach ($needle in $Needles) {
    if (-not $text.Contains($needle)) {
      throw "${Message}: expected '$needle' in $Path"
    }
  }
}

try {
  $spec = Read-OpenApiYamlSubset -Path $OpenApiPath
  Write-Host "[OK] parsed OpenAPI YAML subset: $($spec.Entries.Count) mapping entries, $($spec.SequenceItems.Count) sequence entries"
} catch {
  Add-Failure "[FAIL] parse examples/openapi_admin_skeleton.yaml - $($_.Exception.Message)"
  exit 1
}

$endpoint = New-OpenApiPath @("paths", "/admin/ledger/adjustments/dry-run")
$executeResult = New-OpenApiPath @("components", "schemas", "LedgerAdjustmentExecuteResult")
$executeEnvelope = New-OpenApiPath @("components", "schemas", "LedgerAdjustmentExecuteEnvelope")
$executeContractEnvelope = New-OpenApiPath @("components", "schemas", "LedgerAdjustmentExecuteContractEnvelope")
$executeContract = New-OpenApiPath @("components", "schemas", "LedgerAdjustmentExecuteContract")
$summaryContract = New-OpenApiPath @("components", "schemas", "LedgerAdjustmentExecutorSummaryContract")
$refusalContract = New-OpenApiPath @("components", "schemas", "LedgerAdjustmentExecutorRefusalSummaryContract")
$rollbackContract = New-OpenApiPath @("components", "schemas", "LedgerAdjustmentExecutorRollbackSummaryContract")
$summary = New-OpenApiPath @("components", "schemas", "LedgerAdjustmentExecutorSummary")

Check "ledger adjustment execute endpoint exists" {
  Assert-PathExists -Spec $spec -Path $endpoint -Message "ledger adjustment endpoint"
  Assert-PathExists -Spec $spec -Path (Join-OpenApiPath $endpoint "post") -Message "ledger adjustment POST"
  Assert-ScalarContains -Spec $spec -Path (New-OpenApiPath @($endpoint, "post", "description")) -Needles @(
    "mode=execute",
    "ledger_executor_summary_contract",
    "ledger_executor_summary",
    "raw dedupe material",
    "Authorization/Cookie",
    "payload/body",
    "operation keys are omitted"
  ) -Message "endpoint secret-safe execute description"
}

Check "execute response refs are wired" {
  Assert-PathValue -Spec $spec `
    -Path (New-OpenApiPath @($endpoint, "post", "responses", "200", "content", "application/json", "schema", "oneOf", '$ref')) `
    -Expected "#/components/schemas/LedgerAdjustmentExecuteEnvelope" `
    -Message "HTTP 200 idempotent execute schema"
  Assert-Ref -Spec $spec `
    -Path (New-OpenApiPath @($endpoint, "post", "responses", "201", "content", "application/json", "schema")) `
    -ExpectedRef "#/components/schemas/LedgerAdjustmentExecuteEnvelope" `
    -Message "HTTP 201 applied execute schema"
  Assert-Ref -Spec $spec `
    -Path (New-OpenApiPath @($endpoint, "post", "responses", "501", "content", "application/json", "schema")) `
    -ExpectedRef "#/components/schemas/LedgerAdjustmentExecuteContractEnvelope" `
    -Message "HTTP 501 execute_contract schema"
  Assert-Ref -Spec $spec -Path (New-OpenApiPath @($executeEnvelope, "properties", "data")) -ExpectedRef "#/components/schemas/LedgerAdjustmentExecuteResult" -Message "execute envelope data ref"
}

Check "execute applied/idempotent result schema is locked" {
  Assert-PathExists -Spec $spec -Path $executeResult -Message "execute result schema"
  Assert-ListContains -Spec $spec -Path (Join-OpenApiPath $executeResult "required") -Expected @(
    "mode",
    "outcome",
    "ledger_write",
    "audit_log_write",
    "ledger_executor_summary_contract",
    "ledger_executor_summary",
    "transaction_contract",
    "ledger_entry",
    "validated_plan"
  ) -Message "execute result required fields"
  Assert-ListContains -Spec $spec -Path (New-OpenApiPath @($executeResult, "properties", "outcome", "enum")) -Expected @("applied", "idempotent") -Message "execute result outcomes"
  Assert-PropertyRef -Spec $spec -SchemaPath $executeResult -Property "ledger_executor_summary_contract" -ExpectedRef "#/components/schemas/LedgerAdjustmentExecutorSummaryContract" -Message "execute result summary contract ref"
  Assert-PropertyRef -Spec $spec -SchemaPath $executeResult -Property "ledger_executor_summary" -ExpectedRef "#/components/schemas/LedgerAdjustmentExecutorSummary" -Message "execute result summary ref"
  Assert-PropertyRef -Spec $spec -SchemaPath $executeResult -Property "transaction_contract" -ExpectedRef "#/components/schemas/LedgerAdjustmentExecuteTransactionContract" -Message "execute result transaction ref"
}

Check "execute_contract refusal schema is locked" {
  Assert-PathExists -Spec $spec -Path $executeContractEnvelope -Message "execute_contract envelope schema"
  Assert-ListContains -Spec $spec -Path (New-OpenApiPath @($executeContractEnvelope, "properties", "data", "required")) -Expected @(
    "mode",
    "validated_plan",
    "ledger_executor_summary",
    "execute_contract"
  ) -Message "execute_contract data required fields"
  Assert-PropertyRef -Spec $spec -SchemaPath (New-OpenApiPath @($executeContractEnvelope, "properties", "data")) -Property "ledger_executor_summary" -ExpectedRef "#/components/schemas/LedgerAdjustmentExecutorSummary" -Message "execute_contract data summary ref"
  Assert-PropertyRef -Spec $spec -SchemaPath (New-OpenApiPath @($executeContractEnvelope, "properties", "data")) -Property "execute_contract" -ExpectedRef "#/components/schemas/LedgerAdjustmentExecuteContract" -Message "execute_contract data contract ref"
  Assert-ListContains -Spec $spec -Path (Join-OpenApiPath $executeContract "required") -Expected @(
    "ledger_executor_summary_contract",
    "ledger_executor_refusal_summary_contract",
    "preflight_refusal_summary",
    "transaction_contract",
    "safe_output_contract"
  ) -Message "execute_contract required summary fields"
  Assert-PropertyRef -Spec $spec -SchemaPath $executeContract -Property "ledger_executor_summary_contract" -ExpectedRef "#/components/schemas/LedgerAdjustmentExecutorSummaryContract" -Message "execute_contract summary contract ref"
  Assert-PropertyRef -Spec $spec -SchemaPath $executeContract -Property "ledger_executor_refusal_summary_contract" -ExpectedRef "#/components/schemas/LedgerAdjustmentExecutorRefusalSummaryContract" -Message "execute_contract refusal contract ref"
  Assert-PropertyRef -Spec $spec -SchemaPath $executeContract -Property "preflight_refusal_summary" -ExpectedRef "#/components/schemas/LedgerAdjustmentExecutorSummary" -Message "execute_contract preflight summary ref"
  Assert-ListContains -Spec $spec -Path (New-OpenApiPath @($executeContract, "properties", "transaction_contract", "required")) -Expected @("rollback_executor_summary_contract") -Message "rollback summary contract required"
  Assert-Ref -Spec $spec -Path (New-OpenApiPath @($executeContract, "properties", "transaction_contract", "properties", "rollback_executor_summary_contract")) -ExpectedRef "#/components/schemas/LedgerAdjustmentExecutorRollbackSummaryContract" -Message "rollback summary contract ref"
}

Check "executor summary schemas exist with required shape" {
  foreach ($schema in @($summaryContract, $refusalContract, $rollbackContract, $summary)) {
    Assert-PathExists -Spec $spec -Path $schema -Message "executor summary schema $schema"
  }
  Assert-ListContains -Spec $spec -Path (New-OpenApiPath @($summaryContract, "properties", "schema_version", "enum")) -Expected @("billing_ledger_postgres_executor_summary.v1") -Message "summary contract schema version"
  Assert-PathExists -Spec $spec -Path (New-OpenApiPath @($summaryContract, "properties", "compatible_fields")) -Message "summary contract compatible_fields"
  Assert-ListContains -Spec $spec -Path (Join-OpenApiPath $summary "required") -Expected @(
    "schema_version",
    "executor",
    "operation",
    "outcome",
    "committed",
    "rolled_back",
    "statement_count",
    "executed_statement_count",
    "refused_statement_count",
    "total_rows_affected",
    "final_statement_order",
    "final_statement_kind",
    "row_count_mismatch"
  ) -Message "executor summary required fields"
  Assert-ListContains -Spec $spec -Path (New-OpenApiPath @($summary, "properties", "schema_version", "enum")) -Expected @("billing_ledger_postgres_executor_summary.v1") -Message "executor summary schema version"
  Assert-ListContains -Spec $spec -Path (New-OpenApiPath @($summary, "properties", "executor", "enum")) -Expected @("control_plane_transactional_admin_ledger_adjustment_writer") -Message "executor summary executor marker"
  Assert-ListContains -Spec $spec -Path (New-OpenApiPath @($summary, "properties", "outcome", "enum")) -Expected @("applied", "idempotent", "refused_preflight", "refused_rollback") -Message "executor summary outcomes"
}

Check "secret-safe omission markers are locked" {
  foreach ($schema in @($summaryContract, $refusalContract, $rollbackContract)) {
    Assert-EnumOmitted -Spec $spec -PropertyPath (New-OpenApiPath @($schema, "properties", "operation_key_output")) -Message "$schema operation key output"
    Assert-EnumOmitted -Spec $spec -PropertyPath (New-OpenApiPath @($schema, "properties", "error_detail_output")) -Message "$schema error detail output"
    Assert-ConstFalse -Spec $spec -PropertyPath (New-OpenApiPath @($schema, "properties", "dedupe_material_echoed")) -Message "$schema dedupe material echo"
    Assert-ConstFalse -Spec $spec -PropertyPath (New-OpenApiPath @($schema, "properties", "raw_metadata_echoed")) -Message "$schema raw metadata echo"
    Assert-ConstFalse -Spec $spec -PropertyPath (New-OpenApiPath @($schema, "properties", "credential_material_echoed")) -Message "$schema credential material echo"
  }

  foreach ($schema in @($refusalContract, $rollbackContract, $summary)) {
    Assert-ConstFalse -Spec $spec -PropertyPath (New-OpenApiPath @($schema, "properties", "raw_executor_error_detail_echoed")) -Message "$schema raw executor detail echo"
  }

  Assert-EnumOmitted -Spec $spec -PropertyPath (New-OpenApiPath @($summary, "properties", "operation_key_output")) -Message "executor summary operation key output"
  Assert-EnumOmitted -Spec $spec -PropertyPath (New-OpenApiPath @($summary, "properties", "error_detail_output")) -Message "executor summary error detail output"
  Assert-ConstFalse -Spec $spec -PropertyPath (New-OpenApiPath @($summary, "properties", "dedupe_material_echoed")) -Message "executor summary dedupe material echo"
  Assert-ScalarContains -Spec $spec -Path (New-OpenApiPath @($summary, "properties", "omitted_material", "description")) -Needles @(
    "raw operation key",
    "dedupe material",
    "raw metadata",
    "credentials",
    "Authorization/Cookie headers",
    "payload/body",
    "executor error detail"
  ) -Message "executor summary omitted material description"
}

if ($script:Failures.Count -gt 0) {
  Write-Host ""
  Write-Host "Control Plane ledger adjustment OpenAPI contract validation failed:"
  foreach ($failure in $script:Failures) {
    Write-Host $failure
  }
  exit 1
}

Write-Host "Control Plane ledger adjustment OpenAPI contract validation passed."
