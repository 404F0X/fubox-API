<#
.SYNOPSIS
Writes a local network security config example for trusted proxy and IP allowlists.

.DESCRIPTION
This helper produces documentation-only YAML snippets for local/deployment
operators and the Settings UI. It uses RFC5737 IPv4 and RFC3849 IPv6
documentation ranges only. The output is not a production gate and must be
reviewed against the real reverse proxy and user access policy before use.
#>
param(
  [string]$OutputPath = ".tmp/network-security/network_security_config_example.yaml",
  [switch]$PrintOnly
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

function Resolve-RepoPath {
  param([Parameter(Mandatory = $true)][string]$Path)

  if ([System.IO.Path]::IsPathRooted($Path)) {
    return $Path
  }

  return Join-Path $repoRoot $Path
}

$example = @'
# Fubox API network security config example
#
# Scope:
# - Documentation/local deployment starting point only.
# - Uses RFC5737 IPv4 and RFC3849 IPv6 documentation ranges.
# - Does not contain real client, office, VPN, load balancer, provider, or secret values.
# - Not a production gate; operators must replace examples with reviewed deployment CIDRs.

server:
  # Gateway trusts forwarded client IP headers only when the TCP peer IP matches
  # one of these reverse proxy/load balancer source IPs or CIDRs.
  #
  # Empty list is the safe default:
  # trusted_proxy_allowlist: []
  trusted_proxy_allowlist:
    - "192.0.2.10"
    - "198.51.100.0/24"
    - "2001:db8:100::/48"

admin_api_examples:
  # Profile-level allowlist tightens virtual key allowlists. Empty means the
  # profile does not add an extra IP restriction.
  create_profile_payload:
    name: "example-profile"
    ip_allowlist:
      - "203.0.113.42"
      - "203.0.113.0/24"
      - "2001:db8:200::/48"

  # Virtual key allowlist is evaluated before the profile allowlist.
  # Keep empty for unrestricted local demo keys.
  create_virtual_key_payload:
    name: "example-key"
    ip_allowlist:
      - "203.0.113.42"
      - "2001:db8:200::42"

settings_ui_reference:
  config_path_env: "AI_GATEWAY_CONFIG"
  trusted_proxy_allowlist_path: "server.trusted_proxy_allowlist"
  profile_allowlist_field: "api_key_profiles.ip_allowlist"
  virtual_key_allowlist_field: "virtual_keys.ip_allowlist"
  generated_by: "scripts/write_network_security_config_example.ps1"
'@

$resolvedOutputPath = Resolve-RepoPath -Path $OutputPath

if ($PrintOnly) {
  Write-Output $example
  exit 0
}

$outputDirectory = Split-Path -Parent $resolvedOutputPath
if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory)) {
  New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

Set-Content -LiteralPath $resolvedOutputPath -Value $example -Encoding UTF8
Write-Host "network_security_config_example_status=written"
Write-Host "output_path=$resolvedOutputPath"
Write-Host "trusted_proxy_allowlist_path=server.trusted_proxy_allowlist"
Write-Host "profile_allowlist_field=api_key_profiles.ip_allowlist"
Write-Host "virtual_key_allowlist_field=virtual_keys.ip_allowlist"
Write-Host "production_gate=false"
