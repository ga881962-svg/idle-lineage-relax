$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

if ([string]::IsNullOrWhiteSpace($env:SUPABASE_DB_PASSWORD)) {
  throw 'SUPABASE_DB_PASSWORD is required for independent CLI database connections. Set it only for this test-project PowerShell session before running this script.'
}

function Invoke-Phase0Native([string]$Command, [string[]]$Arguments) {
  # Supabase CLI writes harmless progress text (for example, "Initialising
  # login role...") to stderr. In PowerShell 7 that can become a terminating
  # NativeCommandError when ErrorActionPreference is Stop. Capture both streams
  # and use the process exit code as the sole success/failure signal.
  $savedErrorAction = $ErrorActionPreference
  $hasNativePreference = Test-Path Variable:PSNativeCommandUseErrorActionPreference
  if ($hasNativePreference) { $savedNativePreference = $PSNativeCommandUseErrorActionPreference }
  try {
    $ErrorActionPreference = 'Continue'
    if ($hasNativePreference) { $PSNativeCommandUseErrorActionPreference = $false }
    $output = & $Command @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{ ExitCode = $exitCode; Output = ($output -join "`n") }
  } finally {
    $ErrorActionPreference = $savedErrorAction
    if ($hasNativePreference) { $PSNativeCommandUseErrorActionPreference = $savedNativePreference }
  }
}

function Start-Phase0QueryJob([string]$SqlFile) {
  Start-Job -ScriptBlock {
    param($workdir,$queryFile)
    Set-Location $workdir
    $ErrorActionPreference = 'Continue'
    if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) { $PSNativeCommandUseErrorActionPreference = $false }
    $output = & npx.cmd --yes supabase db query --linked --agent=no -o json -f $queryFile 2>&1
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
  } -ArgumentList $repoRoot,$SqlFile
}

# C / D / N require independent backend connections.  The first transaction
# holds only the ledger row; the second must block, then see `running` rather
# than execute a second action.  Lock timeout turns a deadlock into a failure.
$sql1 = @"
begin;
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',false);
set local role authenticated;
set local lock_timeout='5s';
with begin_result as materialized (
  select public.server_action_begin('aaaaaaaa-0000-4000-8000-000000000001','phase0.test.concurrent','40000000-0000-4000-8000-000000000001',repeat('a',64),'normal','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa') as value
), hold_lock as materialized (
  select pg_sleep(2) from begin_result
)
select jsonb_build_object('begin',begin_result.value,'held',true) as phase0_concurrent_first
from begin_result cross join hold_lock;
commit;
"@
$sql2 = @"
begin;
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',false);
set local role authenticated;
set local lock_timeout='5s';
select public.server_action_begin('aaaaaaaa-0000-4000-8000-000000000001','phase0.test.concurrent','40000000-0000-4000-8000-000000000001',repeat('a',64),'normal','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
commit;
"@

# I: two devices race to create the same migration marker.  The winner holds
# the row; a distinct request ID from the second device must be rejected after
# it waits for the committed marker, never start another import.
$migration1 = @"
begin;
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',false);
set local role authenticated;
set local lock_timeout='5s';
with begin_result as materialized (
  select public.server_migration_begin('aaaaaaaa-0000-4000-8000-000000000001','normal','phase0.test.concurrent-migration','50000000-0000-4000-8000-000000000001',repeat('b',64)) as value
), hold_lock as materialized (
  select pg_sleep(2) from begin_result
)
select jsonb_build_object('begin',begin_result.value,'held',true) as phase0_concurrent_migration_first
from begin_result cross join hold_lock;
commit;
"@
$migration2 = @"
begin;
select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',false);
set local role authenticated;
set local lock_timeout='5s';
select public.server_migration_begin('aaaaaaaa-0000-4000-8000-000000000001','normal','phase0.test.concurrent-migration','50000000-0000-4000-8000-000000000002',repeat('b',64));
commit;
"@

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("phase0-concurrency-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
  $cleanupFile = Join-Path $tempRoot 'cleanup.sql'
  $fullCleanupFile = Join-Path $repoRoot 'tests\sql\phase0-isolated-cleanup.sql'
  $fixtureSetupFile = Join-Path $repoRoot 'tests\sql\phase0-concurrency-fixture-setup.sql'
  $sessionRefreshFile = Join-Path $repoRoot 'tests\sql\phase0-concurrency-session-refresh.sql'
  $ledgerFirstFile = Join-Path $tempRoot 'ledger-first.sql'
  $ledgerSecondFile = Join-Path $tempRoot 'ledger-second.sql'
  $migrationFirstFile = Join-Path $tempRoot 'migration-first.sql'
  $migrationSecondFile = Join-Path $tempRoot 'migration-second.sql'
  $ledgerCheckFile = Join-Path $tempRoot 'ledger-check.sql'
  Set-Content -LiteralPath $cleanupFile -Encoding utf8 -NoNewline -Value "delete from public.server_action_requests where user_id='11111111-1111-4111-8111-111111111111' and action_type='phase0.test.concurrent'; delete from public.server_migration_markers where user_id='11111111-1111-4111-8111-111111111111' and migration_kind='phase0.test.concurrent-migration';"
  Set-Content -LiteralPath $ledgerFirstFile -Encoding utf8 -NoNewline -Value $sql1
  Set-Content -LiteralPath $ledgerSecondFile -Encoding utf8 -NoNewline -Value $sql2
  Set-Content -LiteralPath $migrationFirstFile -Encoding utf8 -NoNewline -Value $migration1
  Set-Content -LiteralPath $migrationSecondFile -Encoding utf8 -NoNewline -Value $migration2
  Set-Content -LiteralPath $ledgerCheckFile -Encoding utf8 -NoNewline -Value "select jsonb_build_object('request_count',count(*),'running_count',count(*) filter (where status='running')) as phase0_ledger_check from public.server_action_requests where user_id='11111111-1111-4111-8111-111111111111' and action_type='phase0.test.concurrent' and request_id='40000000-0000-4000-8000-000000000001';"

  $preCleanupResult = Invoke-Phase0Native 'npx.cmd' @('--yes','supabase','db','query','--linked','--agent=no','-f',$fullCleanupFile)
  if ($preCleanupResult.ExitCode -ne 0) { throw "Could not clear prior Phase 0 fixtures: $($preCleanupResult.Output)" }
  $fixtureSetupResult = Invoke-Phase0Native 'npx.cmd' @('--yes','supabase','db','query','--linked','--agent=no','-f',$fixtureSetupFile)
  if ($fixtureSetupResult.ExitCode -ne 0) { throw "Could not create committed Phase 0 fixtures: $($fixtureSetupResult.Output)" }
  $sessionRefreshResult = Invoke-Phase0Native 'npx.cmd' @('--yes','supabase','db','query','--linked','--agent=no','-f',$sessionRefreshFile)
  if ($sessionRefreshResult.ExitCode -ne 0) { throw "Could not refresh the Phase 0 fixture session: $($sessionRefreshResult.Output)" }
  Write-Host 'Phase 0 fixture session verified by assert_active_game_session.'

  $cleanupResult = Invoke-Phase0Native 'npx.cmd' @('--yes','supabase','db','query','--linked','--agent=no','-f',$cleanupFile)
  if ($cleanupResult.ExitCode -ne 0) { throw "Could not reset disposable concurrency fixtures: $($cleanupResult.Output)" }

  $first = Start-Phase0QueryJob $ledgerFirstFile
  Start-Sleep -Milliseconds 250
  $second = Start-Phase0QueryJob $ledgerSecondFile
  Wait-Job $first,$second | Out-Null
  $firstResult = Receive-Job $first; $secondResult = Receive-Job $second
  Remove-Job $first,$second
  if ($firstResult.ExitCode -ne 0 -or $secondResult.ExitCode -ne 0 -or $firstResult.Output -notmatch 'running' -or $secondResult.Output -notmatch 'running') { throw "Concurrent ledger test failed. First: $($firstResult.Output) Second: $($secondResult.Output)" }
  $ledgerCheckResult = Invoke-Phase0Native 'npx.cmd' @('--yes','supabase','db','query','--linked','--agent=no','-o','json','-f',$ledgerCheckFile)
  if ($ledgerCheckResult.ExitCode -ne 0 -or $ledgerCheckResult.Output -notmatch '"request_count"\s*:\s*1') { throw "Concurrent ledger produced an unexpected number of rows: $($ledgerCheckResult.Output)" }

  $winner = Start-Phase0QueryJob $migrationFirstFile
  Start-Sleep -Milliseconds 250
  $loser = Start-Phase0QueryJob $migrationSecondFile
  Wait-Job $winner,$loser | Out-Null
  $winnerResult = Receive-Job $winner; $loserResult = Receive-Job $loser
  Remove-Job $winner,$loser
  if ($winnerResult.ExitCode -ne 0 -or $winnerResult.Output -notmatch 'running') { throw "Migration winner failed: $($winnerResult.Output)" }
  if ($loserResult.ExitCode -eq 0 -or $loserResult.Output -notmatch 'MIGRATION_IN_PROGRESS_OR_ALREADY_ATTEMPTED') { throw "Migration loser was not rejected: $($loserResult.Output)" }
  Write-Host 'C/D/N concurrent ledger/lock-order and I concurrent migration-marker tests passed.'
} finally {
  if (Test-Path $fullCleanupFile) {
    $finalCleanupResult = Invoke-Phase0Native 'npx.cmd' @('--yes','supabase','db','query','--linked','--agent=no','-f',$fullCleanupFile)
    if ($finalCleanupResult.ExitCode -ne 0) { Write-Warning "Phase 0 fixture cleanup failed: $($finalCleanupResult.Output)" }
  }
  if (Test-Path $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
