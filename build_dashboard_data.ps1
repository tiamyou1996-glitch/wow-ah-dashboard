param(
  [string]$Root = "D:/code/wow-ah"
)

$dataDir = Join-Path $Root "data"
$dashboardDir = Join-Path $Root "dashboard"
$snapshotFile = Join-Path $dataDir "market_snapshots.csv"
$relationsFile = Join-Path $dataDir "relations.csv"
$outFile = Join-Path $dashboardDir "dashboard_data.js"

if (-not (Test-Path $snapshotFile)) {
  throw "Missing snapshots file: $snapshotFile"
}

New-Item -ItemType Directory -Force -Path $dashboardDir | Out-Null

$snapshots = Import-Csv $snapshotFile | ForEach-Object {
  [pscustomobject]@{
    observed_at = $_.observed_at
    item_name = $_.item_name
    rank = [int]$_.rank
    unit_price_gold = [double]$_.unit_price_gold
    unit_price_display = $_.unit_price_display
    available_quantity = [int]$_.available_quantity
    source_type = $_.source_type
    source_ref = $_.source_ref
  }
}

$relations = @()
if (Test-Path $relationsFile) {
  $relations = Import-Csv $relationsFile
}

function Get-WindowStats {
  param(
    [array]$Series,
    [int]$Count
  )
  if ($Series.Count -eq 0) {
    return [pscustomobject]@{ pos = 0.5; avg_qty = 0 }
  }
  $take = [Math]::Min($Count, $Series.Count)
  $w = $Series | Select-Object -Last $take
  $prices = $w | ForEach-Object { [double]$_.unit_price_gold }
  $qtys = $w | ForEach-Object { [double]$_.available_quantity }
  $minP = ($prices | Measure-Object -Minimum).Minimum
  $maxP = ($prices | Measure-Object -Maximum).Maximum
  $cur = [double]($w[-1].unit_price_gold)
  $pos = 0.5
  if ($maxP -gt $minP) {
    $pos = ($cur - $minP) / ($maxP - $minP)
  }
  $avgQ = ($qtys | Measure-Object -Average).Average
  return [pscustomobject]@{
    pos = [Math]::Round($pos, 4)
    avg_qty = [Math]::Round($avgQ, 2)
  }
}

$analysis = [ordered]@{
  title = "merchant_multi_tf"
  generated_at = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  latest_ts = $null
  prev_ts = $null
  confidence = "low"
  signals = @()
}

$distinctTimes = $snapshots | Select-Object -ExpandProperty observed_at -Unique | Sort-Object
if ($distinctTimes.Count -ge 2) {
  $latestTs = $distinctTimes[-1]
  $prevTs = $distinctTimes[-2]
  $analysis.latest_ts = $latestTs
  $analysis.prev_ts = $prevTs
  $analysis.confidence = if ($distinctTimes.Count -ge 6) { "medium" } else { "low" }

  $latestRows = $snapshots | Where-Object { $_.observed_at -eq $latestTs }
  $prevRows = $snapshots | Where-Object { $_.observed_at -eq $prevTs }
  $prevMap = @{}
  foreach ($r in $prevRows) {
    $prevMap["$($r.item_name)|$($r.rank)"] = $r
  }

  $allByKey = @{}
  foreach ($r in ($snapshots | Sort-Object observed_at)) {
    $k = "$($r.item_name)|$($r.rank)"
    if (-not $allByKey.ContainsKey($k)) { $allByKey[$k] = @() }
    $allByKey[$k] += $r
  }

  $signals = @()
  foreach ($r in $latestRows) {
    $k = "$($r.item_name)|$($r.rank)"
    if (-not $allByKey.ContainsKey($k)) { continue }
    $series = $allByKey[$k]
    if ($series.Count -lt 2) { continue }
    $prev = $prevMap[$k]
    if (-not $prev -or [double]$prev.unit_price_gold -eq 0) { continue }

    $pricePct = (([double]$r.unit_price_gold - [double]$prev.unit_price_gold) / [double]$prev.unit_price_gold) * 100.0
    $qtyPct = 0.0
    if ([double]$prev.available_quantity -ne 0) {
      $qtyPct = (([double]$r.available_quantity - [double]$prev.available_quantity) / [double]$prev.available_quantity) * 100.0
    }

    # Count-based windows as a proxy for time ranges:
    # short: ~5-30m, mid: ~2-6h, day: ~24h, week: ~3-7d
    $wShort = Get-WindowStats -Series $series -Count 3
    $wMid = Get-WindowStats -Series $series -Count 12
    $wDay = Get-WindowStats -Series $series -Count 48
    $wWeek = Get-WindowStats -Series $series -Count 200

    $curQty = [double]$r.available_quantity
    $depthRatioMid = 1.0
    if ($wMid.avg_qty -gt 0) {
      $depthRatioMid = $curQty / $wMid.avg_qty
    }

    $restockScore = (1 - $wDay.pos) * 40 + (1 - $wWeek.pos) * 25 + (1 - $wMid.pos) * 20
    if ($depthRatioMid -ge 0.8) { $restockScore += 15 }
    if ($pricePct -le -2 -and $qtyPct -ge 12) { $restockScore -= 18 }

    $sellScore = $wDay.pos * 35 + $wWeek.pos * 25 + $wMid.pos * 15
    if ($depthRatioMid -ge 0.6) { $sellScore += 15 }
    if ($pricePct -ge 2 -and $wShort.pos -ge 0.7) { $sellScore += 10 }

    $avoidScore = 0
    if ($pricePct -le -2 -and $qtyPct -ge 8) { $avoidScore += 45 }
    if ($wShort.pos -le 0.2 -and $wMid.pos -le 0.25) { $avoidScore += 25 }
    if ($depthRatioMid -ge 1.25) { $avoidScore += 20 }

    $restockScore = [Math]::Round([Math]::Max(0, [Math]::Min(100, $restockScore)), 1)
    $sellScore = [Math]::Round([Math]::Max(0, [Math]::Min(100, $sellScore)), 1)
    $avoidScore = [Math]::Round([Math]::Max(0, [Math]::Min(100, $avoidScore)), 1)

    $tag = "watch"
    if ($avoidScore -ge 55) { $tag = "avoid_trap" }
    elseif ($restockScore -ge 62 -and $restockScore -ge ($sellScore + 8)) { $tag = "restock_buy" }
    elseif ($sellScore -ge 62 -and $sellScore -ge ($restockScore + 6)) { $tag = "sell_now" }

    $signals += [pscustomobject]@{
      item = $r.item_name
      rank = $r.rank
      price_pct = [Math]::Round($pricePct, 2)
      qty_pct = [Math]::Round($qtyPct, 2)
      tag = $tag
      scores = [ordered]@{
        restock = $restockScore
        sell = $sellScore
        avoid = $avoidScore
      }
      timeframe_pos = [ordered]@{
        short = [Math]::Round($wShort.pos, 3)
        mid = [Math]::Round($wMid.pos, 3)
        day = [Math]::Round($wDay.pos, 3)
        week = [Math]::Round($wWeek.pos, 3)
      }
      depth_ratio_mid = [Math]::Round($depthRatioMid, 3)
    }
  }
  $analysis.signals = $signals
}

$payload = [ordered]@{
  generated_at = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  snapshots = $snapshots
  relations = $relations
  analysis = $analysis
}

$json = $payload | ConvertTo-Json -Depth 12
$content = "window.WOW_AH_DATA = $json;"
Set-Content -Encoding UTF8 -Path $outFile -Value $content

Write-Output "Dashboard data written: $outFile"
