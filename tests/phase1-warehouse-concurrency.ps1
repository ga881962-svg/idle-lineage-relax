param(
  [ValidateRange(1,2)][int]$StartRound = 1,
  [ValidateRange(1,2)][int]$RoundCount = 2
)
if (($StartRound + $RoundCount - 1) -gt 2) {
  throw 'Round range exceeds the required two isolated runs.'
}

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$expected = 'wladrgqkrmsjazhvxowi'
$linked = (Get-Content -Raw (Join-Path $repoRoot 'supabase\.temp\project-ref')).Trim()
if ($linked -ne $expected) { throw "STOP: linked ref is $linked, expected $expected" }
if ([string]::IsNullOrWhiteSpace($env:SUPABASE_DB_PASSWORD)) {
  throw 'STOP: SUPABASE_DB_PASSWORD is required for the independent backend test connections.'
}

function Invoke-Native([string]$Command, [string[]]$Arguments) {
  $saved = $ErrorActionPreference
  $hasNativePreference = Test-Path Variable:PSNativeCommandUseErrorActionPreference
  if ($hasNativePreference) { $savedNativePreference = $PSNativeCommandUseErrorActionPreference }
  try {
    $ErrorActionPreference = 'Continue'
    if ($hasNativePreference) { $PSNativeCommandUseErrorActionPreference = $false }
    $output = & $Command @Arguments 2>&1
    return [pscustomobject]@{ ExitCode=$LASTEXITCODE; Output=($output -join "`n") }
  } finally {
    $ErrorActionPreference = $saved
    if ($hasNativePreference) { $PSNativeCommandUseErrorActionPreference = $savedNativePreference }
  }
}
function Invoke-LinkedSql([string]$File,[bool]$Json=$false) {
  $args = @('--yes','supabase','db','query','--linked','--agent=no')
  if ($Json) { $args += @('-o','json') }
  $args += @('--file',$File)
  $r = Invoke-Native 'npx.cmd' $args
  if ($r.ExitCode -ne 0) { throw "SQL failed: $File`n$($r.Output)" }
  return $r
}
function Start-Backend([string]$SqlFile) {
  Start-Job -ScriptBlock {
    param($workdir,$file)
    Set-Location $workdir
    $ErrorActionPreference='Continue'
    if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) { $PSNativeCommandUseErrorActionPreference=$false }
    $out=& npx.cmd --yes supabase db query --linked --agent=no -o json --file $file 2>&1
    [pscustomobject]@{ ExitCode=$LASTEXITCODE; Output=($out -join "`n") }
  } -ArgumentList $repoRoot,$SqlFile
}
function Assert-Output([bool]$Condition,[string]$Message) { if (-not $Condition) { throw "PHASE1_CONCURRENCY_FAILED: $Message" } }

$fixture = Join-Path $repoRoot 'tests\sql\phase1-warehouse-fixture.sql'
$setup = Join-Path $repoRoot 'tests\sql\phase1-warehouse-concurrency-setup.sql'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("phase1-warehouse-concurrency-"+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

function Write-Sql([string]$Name,[string]$Sql) {
  $path=Join-Path $tempRoot $Name
  Set-Content -LiteralPath $path -Encoding utf8 -NoNewline -Value $Sql
  return $path
}
function Reset-Scenario([bool]$WithWarehouse=$true) {
  [void](Invoke-LinkedSql $fixture)
  if ($WithWarehouse) { [void](Invoke-LinkedSql $setup) }
}
function Run-Pair([string]$FirstSql,[string]$SecondSql) {
  $firstFile=Write-Sql 'first.sql' $FirstSql; $secondFile=Write-Sql 'second.sql' $SecondSql
  $first=Start-Backend $firstFile; Start-Sleep -Milliseconds 250; $second=Start-Backend $secondFile
  Wait-Job $first,$second | Out-Null
  $a=Receive-Job $first; $b=Receive-Job $second; Remove-Job $first,$second
  return @($a,$b)
}

$auth = "select set_config('request.jwt.claim.sub','11111111-1111-4111-8111-111111111111',true); set local role authenticated; set local lock_timeout='5s';"
$migrationPayload = '$${"gold":2000000,"items":[]}$$'
try {
  for ($round=$StartRound; $round -lt ($StartRound + $RoundCount); $round++) {
    # Same request/payload in two independent backends: one mutation, replay for the other.
    Reset-Scenario $true
    $sameFirst="begin; $auth with x as materialized (select public.warehouse_transfer('aaaaaaaa-0000-4000-8000-000000000001','cccccccc-cccc-4ccc-8ccc-cccccccccccc','20000000-0000-4000-8000-000000000020',20,'withdraw','gold',null,1000000) r), h as materialized (select pg_sleep(2) from x) select jsonb_build_object('result',x.r,'held',true) from x cross join h; commit;"
    $sameSecond="begin; $auth select public.warehouse_transfer('aaaaaaaa-0000-4000-8000-000000000001','cccccccc-cccc-4ccc-8ccc-cccccccccccc','20000000-0000-4000-8000-000000000020',20,'withdraw','gold',null,1000000); commit;"
    $pair=Run-Pair $sameFirst $sameSecond
    Assert-Output ($pair[0].ExitCode -eq 0 -and $pair[1].ExitCode -eq 0 -and $pair[0].Output -match 'held' -and $pair[1].Output -match 'revision') "round $round duplicate request did not replay"
    $check=Write-Sql 'same-check.sql' "select jsonb_build_object('b_revision',(select revision from public.character_checkpoints where character_id='cccccccc-cccc-4ccc-8ccc-cccccccccccc'),'b_gold',(select (state#>>'{p,gold}')::bigint from public.character_checkpoints where character_id='cccccccc-cccc-4ccc-8ccc-cccccccccccc'),'warehouse_gold',(select gold from public.account_warehouses where user_id='11111111-1111-4111-8111-111111111111' and mode_bucket='normal'),'warehouse_revision',(select revision from public.account_warehouses where user_id='11111111-1111-4111-8111-111111111111' and mode_bucket='normal'),'ledger_count',(select count(*) from public.server_action_requests where user_id='11111111-1111-4111-8111-111111111111' and action_type='warehouse.transfer' and request_id='20000000-0000-4000-8000-000000000020')) as duplicate_request;"
    $out=(Invoke-LinkedSql $check $true).Output
    if (-not ($out -match '"b_revision"\s*:\s*21' -and $out -match '"b_gold"\s*:\s*1000100' -and $out -match '"warehouse_gold"\s*:\s*1000000' -and $out -match '"warehouse_revision"\s*:\s*3' -and $out -match '"ledger_count"\s*:\s*1')) {
      throw "PHASE1_CONCURRENCY_FAILED: round $round duplicate request DB assertion failed.`nFIRST_BACKEND:`n$($pair[0].Output)`nSECOND_BACKEND:`n$($pair[1].Output)`nFINAL_DB:`n$out"
    }

    # Different characters race for the same 2m warehouse gold. One may take it;
    # the other must fail insufficient funds, never overdraw or deadlock.
    Reset-Scenario $true
    $goldFirst="begin; $auth with x as materialized (select public.warehouse_transfer('aaaaaaaa-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','20000000-0000-4000-8000-000000000021',12,'withdraw','gold',null,2000000) r), h as materialized (select pg_sleep(2) from x) select jsonb_build_object('result',x.r,'held',true) from x cross join h; commit;"
    $goldSecond="begin; $auth select public.warehouse_transfer('aaaaaaaa-0000-4000-8000-000000000001','cccccccc-cccc-4ccc-8ccc-cccccccccccc','20000000-0000-4000-8000-000000000022',20,'withdraw','gold',null,2000000); commit;"
    $pair=Run-Pair $goldFirst $goldSecond
    Assert-Output ($pair[0].ExitCode -eq 0 -and $pair[1].ExitCode -ne 0 -and $pair[1].Output -match 'INSUFFICIENT_WAREHOUSE_GOLD') "round $round gold overdraw was not rejected"
    $check=Write-Sql 'gold-check.sql' "select jsonb_build_object('warehouse_gold',(select gold from public.account_warehouses where user_id='11111111-1111-4111-8111-111111111111' and mode_bucket='normal'),'a_gold',(select state#>>'{p,gold}' from public.character_checkpoints where character_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'),'b_gold',(select state#>>'{p,gold}' from public.character_checkpoints where character_id='cccccccc-cccc-4ccc-8ccc-cccccccccccc')) as gold_race;"
    $out=(Invoke-LinkedSql $check $true).Output
    Assert-Output ($out -match '"warehouse_gold"\s*:\s*0' -and $out -match '"a_gold"\s*:\s*4672844' -and $out -match '"b_gold"\s*:\s*100') "round $round gold race overdrawed or lost state"

    # Different characters race for one UID in warehouse. The second must see
    # the item absent after the first commits; exactly one inventory owns it.
    Reset-Scenario $true
    $uidFirst="begin; $auth with x as materialized (select public.warehouse_transfer('aaaaaaaa-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','20000000-0000-4000-8000-000000000023',12,'withdraw','item','phase1-equip-a',1) r), h as materialized (select pg_sleep(2) from x) select jsonb_build_object('result',x.r,'held',true) from x cross join h; commit;"
    $uidSecond="begin; $auth select public.warehouse_transfer('aaaaaaaa-0000-4000-8000-000000000001','cccccccc-cccc-4ccc-8ccc-cccccccccccc','20000000-0000-4000-8000-000000000024',20,'withdraw','item','phase1-equip-a',1); commit;"
    $pair=Run-Pair $uidFirst $uidSecond
    Assert-Output ($pair[0].ExitCode -eq 0 -and $pair[1].ExitCode -ne 0 -and $pair[1].Output -match 'WAREHOUSE_ITEM_NOT_FOUND') "round $round UID double-withdraw was not rejected"
    $check=Write-Sql 'uid-check.sql' "select jsonb_build_object('warehouse_uid_count',(select count(*) from public.account_warehouse_items where user_id='11111111-1111-4111-8111-111111111111' and mode_bucket='normal' and item_uid='phase1-equip-a'),'inventory_uid_count',(select count(*) from public.character_checkpoints c cross join lateral jsonb_array_elements(c.state#>'{p,inv}') x where c.character_id in ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','cccccccc-cccc-4ccc-8ccc-cccccccccccc') and x.value->>'uid'='phase1-equip-a')) as uid_race;"
    $out=(Invoke-LinkedSql $check $true).Output
    Assert-Output ($out -match '"warehouse_uid_count"\s*:\s*0' -and $out -match '"inventory_uid_count"\s*:\s*1') "round $round UID ownership is not unique"

    # Actual two-device migration of the same account/mode imports one legacy
    # bucket only; the second request safely replays completed metadata.
    Reset-Scenario $false
    $migFirst="begin; $auth with x as materialized (select public.warehouse_migrate('aaaaaaaa-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','20000000-0000-4000-8000-000000000030',${migrationPayload}::jsonb) r), h as materialized (select pg_sleep(2) from x) select jsonb_build_object('result',x.r,'held',true) from x cross join h; commit;"
    $migSecond="begin; $auth select public.warehouse_migrate('aaaaaaaa-0000-4000-8000-000000000001','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','20000000-0000-4000-8000-000000000031',${migrationPayload}::jsonb); commit;"
    $pair=Run-Pair $migFirst $migSecond
    Assert-Output ($pair[0].ExitCode -eq 0 -and $pair[1].ExitCode -eq 0 -and $pair[0].Output -match 'held' -and $pair[1].Output -match 'replayed') "round $round migration did not serialize/replay"
    $check=Write-Sql 'migration-check.sql' "select jsonb_build_object('warehouse_gold',(select gold from public.account_warehouses where user_id='11111111-1111-4111-8111-111111111111' and mode_bucket='normal'),'warehouse_rows',(select count(*) from public.account_warehouses where user_id='11111111-1111-4111-8111-111111111111' and mode_bucket='normal'),'marker_status',(select status from public.server_migration_markers where user_id='11111111-1111-4111-8111-111111111111' and mode_bucket='normal' and migration_kind='warehouse.localstorage.v1')) as migration_race;"
    $out=(Invoke-LinkedSql $check $true).Output
    Assert-Output ($out -match '"warehouse_gold"\s*:\s*2000000' -and $out -match '"warehouse_rows"\s*:\s*1' -and $out -match '"marker_status"\s*:\s*"completed"') "round $round migration double-imported"
    Assert-Output ($pair[0].Output -notmatch 'deadlock|lock timeout|canceling statement due to lock timeout' -and $pair[1].Output -notmatch 'deadlock|lock timeout|canceling statement due to lock timeout') "round $round deadlock or lock timeout"
    Write-Host "Phase 1 concurrency round $round PASS"
  }
  Write-Host 'PHASE1_CONCURRENCY_PASS: two rounds passed (duplicate replay, gold overdraw, UID race, migration race, lock order).'
} finally {
  if (Test-Path $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
