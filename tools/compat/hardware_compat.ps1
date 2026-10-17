param(
    [ValidateSet("doctor", "acquire-sdks", "run")]
    [string]$Mode = "run",
    [string]$Matrix = "tools/compat/compat_matrix.json",
    [string]$Models = "tools/compat/model_capabilities.json",
    [string]$Out = "reports/compat/current-run",
    [switch]$Strict
)

$ErrorActionPreference = "Stop"

function RepoRoot {
    $d = (Get-Location).Path
    while ($d) {
        if (Test-Path (Join-Path $d ".git")) { return $d }
        $p = Split-Path -Parent $d
        if ($p -eq $d) { break }
        $d = $p
    }
    throw "Repository root not found"
}

function PlatformName {
    if ($env:OS -eq "Windows_NT") { return "windows" }
    if ($IsMacOS) { return "macos" }
    return "linux"
}

function Items($x) {
    if ($null -eq $x) { return @() }
    return @($x)
}

function Applies($platforms, [string]$platform) {
    if (-not $platforms) { return $true }
    return ((Items $platforms) -contains "all") -or ((Items $platforms) -contains $platform)
}

function Rel([string]$root, [string]$path) {
    $full = [IO.Path]::GetFullPath($path)
    $base = [IO.Path]::GetFullPath($root).TrimEnd("\", "/")
    if ($full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($base.Length).TrimStart("\", "/").Replace("\", "/")
    }
    return $full.Replace("\", "/")
}

function Files([string]$root) {
    $skip = @(".git", ".dart_tool", "target", "build", "ephemeral", ".claude", ".worktrees")
    @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object {
        $parts = $_.FullName.Substring($root.Length).Split([char[]]@('\', '/'))
        -not ($parts | Where-Object { $skip -contains $_ })
    })
}

function MatchFiles([string]$root, [string]$pattern, $files) {
    $wc = [System.Management.Automation.WildcardPattern]::new($pattern.Replace("\", "/"), [System.Management.Automation.WildcardOptions]::IgnoreCase)
    @($files | Where-Object { $wc.IsMatch((Rel $root $_.FullName)) })
}

function HasTextSymbol([string]$root, $files, [string]$symbol) {
    foreach ($f in $files) {
        try {
            $txt = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($f.FullName))
            if ($txt.Contains($symbol)) { return (Rel $root $f.FullName) }
        } catch {}
    }
    return $null
}

function U16($bytes, [int]$offset) { [BitConverter]::ToUInt16($bytes, $offset) }
function U32($bytes, [int]$offset) { [BitConverter]::ToUInt32($bytes, $offset) }

function ReadCString($bytes, [int]$offset) {
    $end = $offset
    while ($end -lt $bytes.Length -and $bytes[$end] -ne 0) { $end++ }
    if ($end -le $offset) { return "" }
    [Text.Encoding]::ASCII.GetString($bytes, $offset, $end - $offset)
}

function GetPeExports([string]$path) {
    try {
        $bytes = [IO.File]::ReadAllBytes($path)
        if ($bytes.Length -lt 0x100 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) { return @() }
        $pe = U32 $bytes 0x3c
        if ($pe + 0x18 -ge $bytes.Length) { return @() }
        if ($bytes[$pe] -ne 0x50 -or $bytes[$pe + 1] -ne 0x45) { return @() }

        $sectionCount = U16 $bytes ($pe + 6)
        $optionalSize = U16 $bytes ($pe + 20)
        $optional = $pe + 24
        $magic = U16 $bytes $optional
        $dataDirectory = if ($magic -eq 0x20b) { $optional + 112 } else { $optional + 96 }
        if ($dataDirectory + 8 -gt $bytes.Length) { return @() }
        $exportRva = U32 $bytes $dataDirectory
        if ($exportRva -eq 0) { return @() }

        $sections = @()
        $sectionTable = $optional + $optionalSize
        for ($i = 0; $i -lt $sectionCount; $i++) {
            $o = $sectionTable + ($i * 40)
            if ($o + 40 -gt $bytes.Length) { break }
            $virtualSize = U32 $bytes ($o + 8)
            $virtualAddress = U32 $bytes ($o + 12)
            $rawSize = U32 $bytes ($o + 16)
            $rawPointer = U32 $bytes ($o + 20)
            $span = [Math]::Max($virtualSize, $rawSize)
            $sections += [pscustomobject]@{ va=$virtualAddress; size=$span; raw=$rawPointer }
        }
        function RvaToOffset([uint32]$rva, $sections) {
            foreach ($s in $sections) {
                if ($rva -ge $s.va -and $rva -lt ($s.va + $s.size)) {
                    return [int]($s.raw + ($rva - $s.va))
                }
            }
            return -1
        }

        $exportOffset = RvaToOffset $exportRva $sections
        if ($exportOffset -lt 0 -or $exportOffset + 40 -gt $bytes.Length) { return @() }
        $nameCount = U32 $bytes ($exportOffset + 24)
        $namesRva = U32 $bytes ($exportOffset + 32)
        $namesOffset = RvaToOffset $namesRva $sections
        if ($namesOffset -lt 0) { return @() }

        $exports = @()
        for ($i = 0; $i -lt $nameCount; $i++) {
            $nameRvaOffset = $namesOffset + ($i * 4)
            if ($nameRvaOffset + 4 -gt $bytes.Length) { break }
            $nameOffset = RvaToOffset (U32 $bytes $nameRvaOffset) $sections
            if ($nameOffset -ge 0 -and $nameOffset -lt $bytes.Length) {
                $name = ReadCString $bytes $nameOffset
                if ($name) { $exports += $name }
            }
        }
        return $exports
    } catch {
        return @()
    }
}

function FindRuntimeSymbol([string]$root, $files, [string]$symbol) {
    if ($env:OS -ne "Windows_NT") { return $null }
    $dlls = @($files | Where-Object { $_.Extension -ieq ".dll" })
    foreach ($dll in $dlls) {
        $exports = GetPeExports $dll.FullName
        if ($exports -contains $symbol) { return (Rel $root $dll.FullName) }
    }
    return $null
}

function CommandExists([string]$root, [string]$name) {
    if (Test-Path (Join-Path $root $name)) { return $true }
    return $null -ne (Get-Command $name -ErrorAction SilentlyContinue)
}

function RunCommand([string]$root, $cmd, [string[]]$libraryDirs) {
    $cwd = if ($cmd.cwd) { Join-Path $root $cmd.cwd } else { $root }
    $oldPath = $env:PATH
    $oldLd = $env:LD_LIBRARY_PATH
    $oldDyld = $env:DYLD_LIBRARY_PATH
    try {
        $dirs = @($libraryDirs | Where-Object { $_ } | Select-Object -Unique)
        $libRaw = Join-Path $root "lib/libraw"
        if (Test-Path $libRaw) { $dirs += $libRaw }
        if ($dirs.Count -gt 0) {
            $prefix = ($dirs -join [IO.Path]::PathSeparator)
            $env:PATH = $prefix + [IO.Path]::PathSeparator + $env:PATH
            $env:LD_LIBRARY_PATH = $prefix + [IO.Path]::PathSeparator + $env:LD_LIBRARY_PATH
            $env:DYLD_LIBRARY_PATH = $prefix + [IO.Path]::PathSeparator + $env:DYLD_LIBRARY_PATH
        }
        $args = @($cmd.args | ForEach-Object { [string]$_ })
        Push-Location $cwd
        $oldEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $output = & $cmd.program @args 2>&1 | Out-String
        } finally {
            $ErrorActionPreference = $oldEap
            Pop-Location
        }
        $status = $LASTEXITCODE
        [pscustomobject]@{ success = ($status -eq 0); status = $status; output = $output }
    } finally {
        $env:PATH = $oldPath
        $env:LD_LIBRARY_PATH = $oldLd
        $env:DYLD_LIBRARY_PATH = $oldDyld
    }
}

function Tail([string]$s, [int]$lines = 45) {
    if (-not $s) { return "" }
    (($s -split "`r?`n") | Select-Object -Last $lines) -join "`n"
}

function HasUnavailable([string]$s) {
    $l = $s.ToLowerInvariant()
    foreach ($x in @("available=false", "sdk not loaded", "sdk not available", "failed to load", "not found. install", "may not be installed")) {
        if ($l.Contains($x)) { return $true }
    }
    return $false
}

function HasBlockedEvidence([string]$s) {
    if (-not $s) { return $false }
    return $s -match "\b[1-9][0-9]* blocked\b"
}

function AcquireConformU([string]$root) {
    $dest = Join-Path $root "tools/compat/downloads/conformu"
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/ASCOMInitiative/ConformU/releases/latest" -Headers @{ "User-Agent" = "Skotiq-compat-suite" }
    $platform = PlatformName
    $asset = $null
    if ($platform -eq "windows") {
        $asset = @($release.assets | Where-Object { $_.name -match "ConformU\..*\.Setup\.exe$" } | Select-Object -First 1)
    } elseif ($platform -eq "macos") {
        $asset = @($release.assets | Where-Object { $_.name -match "\.dmg$" } | Select-Object -First 1)
    } else {
        $asset = @($release.assets | Where-Object { $_.name -match "linux-x64\.tar\.xz$" } | Select-Object -First 1)
    }
    if (-not $asset) {
        Write-Host "ConformU acquisition: no matching asset found for $platform in $($release.tag_name)"
        return
    }

    $target = Join-Path $dest $asset.name
    if (-not (Test-Path $target)) {
        Write-Host "Downloading ConformU $($release.tag_name) official asset: $($asset.name)"
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $target -Headers @{ "User-Agent" = "Skotiq-compat-suite" }
    } else {
        Write-Host "ConformU $($release.tag_name) asset already present: $target"
    }

    [pscustomobject]@{
        tool = "ConformU"
        release = $release.tag_name
        asset = $asset.name
        url = $asset.browser_download_url
        path = (Rel $root $target)
        note = "Downloaded only. Install or add ConformU to PATH before the official conformance target can run."
    } | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 (Join-Path $dest "conformu-release.json")
}

function NewFunc($target, $check, [string]$verdict, [string]$reason, $evidence) {
    [pscustomobject]@{
        target_id = $target.id
        check_id = $check.id
        manufacturer = $target.manufacturer
        device = $check.device
        function = $check.function
        capability = $check.capability
        verdict = $verdict
        reason = $reason
        physical_required = [bool]$check.physical
        evidence = @(Items $evidence)
    }
}

function NewModel($model, [string]$targetVerdict, $functionByCapability, $functionByCheckId) {
    if ($null -eq $functionByCapability) { $functionByCapability = @{} }
    if ($null -eq $functionByCheckId) { $functionByCheckId = @{} }
    $aliases = @{
        read_filter = @("read_filter", "set_filter")
        read_position = @("read_position", "slew", "move_focuser")
        expose = @("expose", "download_image", "stream", "release")
        download_image = @("download_image", "stream")
        cooler = @("cooler", "controls")
        connect = @("connect", "download_image", "set_filter", "slew")
        enumerate = @("enumerate", "download_image")
    }
    $caps = @()
    $missing = @()
    foreach ($cap in (Items $model.capabilities)) {
        $candidateCaps = if ($aliases.ContainsKey($cap)) { $aliases[$cap] } else { @($cap) }
        $f = $null
        foreach ($candidate in $candidateCaps) {
            if ($functionByCapability[$candidate] -and $functionByCapability[$candidate].verdict -eq "pass") {
                $f = $functionByCapability[$candidate]
                break
            }
        }
        if ($f -and $f.verdict -eq "pass") {
            $caps += [pscustomobject]@{ capability = $cap; verdict = "pass"; evidence = $f.check_id; physical_required = $f.physical_required }
        } else {
            $missing += $cap
            $caps += [pscustomobject]@{ capability = $cap; verdict = if ($targetVerdict -eq "blocked" -or $targetVerdict -eq "skipped") { "blocked" } else { "fail" }; evidence = $null; physical_required = $true }
        }
    }

    $contractResults = @()
    foreach ($contract in (Items $model.contracts)) {
        $evidenceCheck = $contract.evidence_check
        $evidenceFunction = if ($evidenceCheck) { $functionByCheckId[$evidenceCheck] } else { $null }
        $contractPasses = $targetVerdict -eq "pass" -and ((-not $evidenceCheck) -or ($evidenceFunction -and $evidenceFunction.verdict -eq "pass"))
        $contractVerdict = if ($contractPasses) { "pass" } elseif ($targetVerdict -eq "blocked" -or $targetVerdict -eq "skipped") { "blocked" } else { "fail" }
        if ($contractVerdict -ne "pass") { $missing += "contract:$($contract.id)" }
        $contractResults += [pscustomobject]@{
            id = $contract.id
            property = $contract.property
            expectation = $contract.expectation
            evidence = $evidenceCheck
            verdict = $contractVerdict
        }
    }

    $verdict = if ($targetVerdict -eq "pass" -and $missing.Count -eq 0) { "pass" } elseif ($targetVerdict -eq "blocked" -or $targetVerdict -eq "skipped") { "blocked" } else { "fail" }
    $reason = if ($missing.Count -eq 0) { "declared capabilities and model contracts map to passing evidence" } else { "missing evidence for: $($missing -join ', ')" }
    [pscustomobject]@{
        target_id = $model.target_id
        manufacturer = $model.manufacturer
        model = $model.model
        family = $model.family
        device = $model.device
        evidence_grade = $model.evidence_grade
        verdict = $verdict
        reason = $reason
        capabilities = $caps
        contracts = $contractResults
    }
}

function RenderMarkdown($report) {
    $lines = @("# Skotiq Hardware Compatibility Evidence", "")
    $lines += "- Generated: $($report.generated_at)"
    $lines += "- Platform: ``$($report.platform)``"
    $lines += "- Targets: $($report.summary.pass) pass, $($report.summary.fail) fail, $($report.summary.blocked) blocked, $($report.summary.skipped) skipped"
    $lines += "- Functions: $($report.function_summary.pass) pass, $($report.function_summary.fail) fail, $($report.function_summary.blocked) blocked"
    $lines += "- Models: $($report.model_summary.pass) pass, $($report.model_summary.fail) fail, $($report.model_summary.blocked) blocked"
    $lines += ""
    $lines += "## Targets"
    $lines += "| Verdict | Target | Manufacturer | Device | Driver | Tier | Reason |"
    $lines += "|---|---|---|---|---|---|---|"
    foreach ($r in $report.results) { $lines += "| $($r.verdict) | ``$($r.target_id)`` | $($r.manufacturer) | $($r.device_type) | $($r.driver_type) | $($r.confidence_tier) | $($r.reason -replace '\|','\\|') |" }
    $lines += ""
    $lines += "## Function Evidence"
    $lines += "| Verdict | Target | Device | Capability | Function | Physical Required | Reason |"
    $lines += "|---|---|---|---|---|---|---|"
    foreach ($f in $report.function_results) { $lines += "| $($f.verdict) | ``$($f.target_id)`` | $($f.device) | $($f.capability) | $($f.function) | $($f.physical_required) | $($f.reason -replace '\|','\\|') |" }
    $lines += ""
    $lines += "## Model Capability Evidence"
    $lines += "| Verdict | Manufacturer | Model | Device | Family | Grade | Reason |"
    $lines += "|---|---|---|---|---|---|---|"
    foreach ($m in $report.model_results) { $lines += "| $($m.verdict) | $($m.manufacturer) | $($m.model) | $($m.device) | $($m.family) | $($m.evidence_grade) | $($m.reason -replace '\|','\\|') |" }
    $lines += ""
    $lines += "## Model Capability Details"
    $lines += "| Verdict | Manufacturer | Model | Capability | Evidence Check | Physical Required |"
    $lines += "|---|---|---|---|---|---|"
    foreach ($m in $report.model_results) {
        foreach ($c in (Items $m.capabilities)) {
            $ev = if ($c.evidence) { "``$($c.evidence)``" } else { "" }
            $lines += "| $($c.verdict) | $($m.manufacturer) | $($m.model) | $($c.capability) | $ev | $($c.physical_required) |"
        }
    }
    $contractRows = @()
    foreach ($m in $report.model_results) {
        foreach ($c in (Items $m.contracts)) {
            $contractRows += [pscustomobject]@{ model=$m; contract=$c }
        }
    }
    if ($contractRows.Count -gt 0) {
        $lines += ""
        $lines += "## Model Contract Details"
        $lines += "| Verdict | Manufacturer | Model | Property | Expectation | Evidence Check |"
        $lines += "|---|---|---|---|---|---|"
        foreach ($row in $contractRows) {
            $ev = if ($row.contract.evidence) { "``$($row.contract.evidence)``" } else { "" }
            $lines += "| $($row.contract.verdict) | $($row.model.manufacturer) | $($row.model.model) | $($row.contract.property) | $($row.contract.expectation -replace '\|','\\|') | $ev |"
        }
    }
    $lines += ""
    $lines += "## Blocked"
    $blocked = @($report.results | Where-Object { $_.verdict -eq "blocked" })
    if ($blocked.Count -eq 0) { $lines += "- None" } else { foreach ($b in $blocked) { $lines += "- ``$($b.target_id)``: $($b.reason)" } }
    $lines -join "`n"
}

function RenderJUnit($report) {
    $modelCapabilities = @()
    foreach ($m in $report.model_results) {
        foreach ($c in (Items $m.capabilities)) {
            $modelCapabilities += [pscustomobject]@{
                target_id = $m.target_id
                model = $m.model
                capability = $c.capability
                verdict = $c.verdict
                reason = if ($c.evidence) { "mapped to $($c.evidence)" } else { $m.reason }
            }
        }
        foreach ($c in (Items $m.contracts)) {
            $modelCapabilities += [pscustomobject]@{
                target_id = $m.target_id
                model = $m.model
                capability = "contract:$($c.id)"
                verdict = $c.verdict
                reason = if ($c.evidence) { "$($c.property) = $($c.expectation), mapped to $($c.evidence)" } else { $m.reason }
            }
        }
    }
    $allCases = @($report.results + $report.function_results + $report.model_results + $modelCapabilities)
    $tests = $allCases.Count
    $failures = @($allCases | Where-Object { $_.verdict -eq "fail" }).Count
    $skipped = @($allCases | Where-Object { $_.verdict -in @("blocked", "skipped") }).Count
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine("<?xml version=`"1.0`" encoding=`"UTF-8`"?>")
    [void]$sb.AppendLine("<testsuite name=`"skotiq_hardware_compat`" tests=`"$tests`" failures=`"$failures`" skipped=`"$skipped`">")
    foreach ($x in $allCases) {
        $name = if ($x.check_id) { "$($x.target_id)::$($x.check_id)" } elseif ($x.model -and $x.capability) { "$($x.target_id)::$($x.model)::$($x.capability)" } elseif ($x.model) { "$($x.target_id)::$($x.model)" } elseif ($x.target_id) { $x.target_id } else { "unknown" }
        [void]$sb.AppendLine("  <testcase classname=`"compat`" name=`"$([Security.SecurityElement]::Escape($name))`">")
        if ($x.verdict -eq "fail") { [void]$sb.AppendLine("    <failure message=`"$([Security.SecurityElement]::Escape($x.reason))`" />") }
        if ($x.verdict -in @("blocked", "skipped")) { [void]$sb.AppendLine("    <skipped message=`"$([Security.SecurityElement]::Escape($x.reason))`" />") }
        [void]$sb.AppendLine("  </testcase>")
    }
    [void]$sb.AppendLine("</testsuite>")
    $sb.ToString()
}

$root = RepoRoot
$platform = PlatformName
$matrixPath = if ([IO.Path]::IsPathRooted($Matrix)) { $Matrix } else { Join-Path $root $Matrix }
$modelPath = if ([IO.Path]::IsPathRooted($Models)) { $Models } else { Join-Path $root $Models }
$matrixData = Get-Content -Raw $matrixPath | ConvertFrom-Json
$modelData = Get-Content -Raw $modelPath | ConvertFrom-Json
$allFiles = Files $root
$results = @()
$functions = @()
$targetFunctionMap = @{}

if ($Mode -eq "acquire-sdks") {
    Write-Host "SDK acquisition is intentionally conservative. Public downloads already found under tools/compat/downloads are preserved; license-gated SDKs remain blocked until credentials/approval are available."
    AcquireConformU $root
}

foreach ($target in (Items $matrixData.targets)) {
    $evidence = @{}
    $matched = @()
    $libDirs = @()
    $blockers = @()
    $failures = @()

    if (-not (Applies $target.platforms $platform)) {
        $res = [pscustomobject]@{ target_id=$target.id; manufacturer=$target.manufacturer; device_type=$target.device_type; driver_type=$target.driver_type; confidence_tier=$target.confidence_tier; verdict="skipped"; reason="target is not applicable to $platform"; evidence=$evidence }
        $results += $res
        $targetFunctionMap[$target.id] = [pscustomobject]@{ verdict="skipped"; functions=@{}; checks=@{} }
        continue
    }
    if ($target.blocked) { $blockers += $target.blocked }

    foreach ($tool in (Items $target.required_tools)) {
        $ok = CommandExists $root $tool
        $evidence["tool:$tool"] = [string]$ok
        if (-not $ok) { $blockers += "required tool ``$tool`` was not found" }
    }

    foreach ($p in (Items $target.patterns)) {
        $m = MatchFiles $root $p $allFiles
        $evidence["pattern:$p"] = [string]$m.Count
        if ($m.Count -gt 0) {
            $matched += $m
            $libDirs += @($m | ForEach-Object { Split-Path -Parent $_.FullName })
            $evidence["pattern_sample:$p"] = (@($m | Select-Object -First 3 | ForEach-Object { Rel $root $_.FullName }) -join "; ")
        }
    }
    if ($target.patterns -and $matched.Count -eq 0) { $blockers += "no SDK artifacts matched declared patterns" }

    foreach ($s in (Items $target.required_symbols)) {
        $textFound = if ($matched.Count -gt 0) { HasTextSymbol $root $matched $s } else { $null }
        $runtimeFound = if ([bool]$target.runtime_probe -and $matched.Count -gt 0) { FindRuntimeSymbol $root $matched $s } else { $null }
        $evidence["symbol:$s"] = if ($runtimeFound) { "runtime:$runtimeFound" } elseif ($textFound) { "text:$textFound" } else { "missing" }
        if ([bool]$target.runtime_probe -and -not $runtimeFound -and $matched.Count -gt 0) {
            $failures += "runtime symbol ``$s`` was not resolvable from matched DLLs"
        } elseif (-not [bool]$target.runtime_probe -and -not $textFound -and $matched.Count -gt 0) {
            $failures += "required symbol ``$s`` was missing"
        }
    }

    $fList = @()
    foreach ($check in (Items $target.function_checks)) {
        if ($blockers.Count -gt 0) {
            $fList += NewFunc $target $check "blocked" ($blockers -join "; ") @()
            continue
        }
        $missing = @()
        $ev = @()
        foreach ($s in (Items $check.symbols)) {
            $runtimeFound = if ([bool]$target.runtime_probe -and $matched.Count -gt 0) { FindRuntimeSymbol $root $matched $s } else { $null }
            $textFound = if ($matched.Count -gt 0) { HasTextSymbol $root $matched $s } else { "protocol-or-simulator" }
            if ($runtimeFound) {
                $ev += "$s@runtime:$runtimeFound"
            } elseif (-not [bool]$target.runtime_probe -and $textFound) {
                $ev += "$s@text:$textFound"
            } elseif ($check.symbols.Count -eq 0) {
                $ev += "protocol-or-simulator"
            } else {
                $missing += $s
            }
        }
        if ($missing.Count -gt 0) {
            $fList += NewFunc $target $check "fail" "missing runtime/API symbols: $($missing -join ', ')" $ev
            $failures += "function ``$($check.id)`` failed"
        } else {
            $reason = if ($check.physical) { "runtime/API surface present; physical behavior still requires hardware" } else { "simulator/protocol/software evidence passed" }
            $fList += NewFunc $target $check "pass" $reason $ev
        }
    }

    if ($Mode -eq "run" -and $blockers.Count -eq 0) {
        foreach ($cmd in (Items $target.commands)) {
            $cr = RunCommand $root $cmd @($libDirs | Select-Object -Unique)
            $evidence["command:$($cmd.name):status"] = [string]$cr.status
            $evidence["command:$($cmd.name):output_tail"] = Tail $cr.output
            if (-not $cr.success) { $failures += "command ``$($cmd.name)`` exited with $($cr.status)" }
            if (HasUnavailable $cr.output) { $failures += "command ``$($cmd.name)`` reported unavailable SDK" }
            if ((HasBlockedEvidence $cr.output) -and (-not (HasUnavailable $cr.output))) { $blockers += "command ``$($cmd.name)`` reported blocked evidence" }
        }
    }

    $verdict = if ($failures.Count -gt 0) { "fail" } elseif ($blockers.Count -gt 0) { "blocked" } else { "pass" }
    $reason = if ($failures.Count -gt 0) { $failures -join "; " } elseif ($blockers.Count -gt 0) { $blockers -join "; " } elseif ($Mode -eq "run") { "declared runtime/API prerequisites and compatibility commands passed" } else { "declared runtime/API prerequisites are present" }
    $res = [pscustomobject]@{ target_id=$target.id; manufacturer=$target.manufacturer; device_type=$target.device_type; driver_type=$target.driver_type; confidence_tier=$target.confidence_tier; verdict=$verdict; reason=$reason; evidence=$evidence }
    $results += $res
    $functions += $fList
    $capMap = @{}
    foreach ($f in $fList) { if ($f.capability -and -not $capMap.ContainsKey($f.capability)) { $capMap[$f.capability] = $f } }
    $checkMap = @{}
    foreach ($f in $fList) { if ($f.check_id -and -not $checkMap.ContainsKey($f.check_id)) { $checkMap[$f.check_id] = $f } }
    $targetFunctionMap[$target.id] = [pscustomobject]@{ verdict=$verdict; functions=$capMap; checks=$checkMap }
}

$modelResults = @()
foreach ($m in (Items $modelData.models)) {
    $tf = $targetFunctionMap[$m.target_id]
    if ($tf) { $modelResults += NewModel $m $tf.verdict $tf.functions $tf.checks }
}

function CountVerdict($items, [string]$v) { @($items | Where-Object { $_.verdict -eq $v }).Count }
$report = [pscustomobject]@{
    generated_at = [datetime]::UtcNow.ToString("o")
    platform = $platform
    strict = [bool]$Strict
    summary = [pscustomobject]@{ pass=CountVerdict $results "pass"; fail=CountVerdict $results "fail"; blocked=CountVerdict $results "blocked"; skipped=CountVerdict $results "skipped" }
    function_summary = [pscustomobject]@{ pass=CountVerdict $functions "pass"; fail=CountVerdict $functions "fail"; blocked=CountVerdict $functions "blocked" }
    model_summary = [pscustomobject]@{ pass=CountVerdict $modelResults "pass"; fail=CountVerdict $modelResults "fail"; blocked=CountVerdict $modelResults "blocked" }
    results = $results
    function_results = $functions
    model_results = $modelResults
}

$outPath = if ([IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path $root $Out }
if ($Mode -eq "run" -or $Mode -eq "doctor") {
    New-Item -ItemType Directory -Force -Path $outPath | Out-Null
    $report | ConvertTo-Json -Depth 30 | Set-Content -Encoding UTF8 (Join-Path $outPath "results.json")
    RenderMarkdown $report | Set-Content -Encoding UTF8 (Join-Path $outPath "compatibility-report.md")
    RenderJUnit $report | Set-Content -Encoding UTF8 (Join-Path $outPath "junit.xml")
}

Write-Host "Skotiq compatibility: $($report.summary.pass) passed, $($report.summary.fail) failed, $($report.summary.blocked) blocked, $($report.summary.skipped) skipped; functions $($report.function_summary.pass)/$($report.function_summary.fail)/$($report.function_summary.blocked); models $($report.model_summary.pass)/$($report.model_summary.fail)/$($report.model_summary.blocked) ($platform)"
if ($report.summary.fail -gt 0 -or $report.function_summary.fail -gt 0 -or $report.model_summary.fail -gt 0 -or ($Strict -and $report.summary.pass -eq 0)) { exit 1 }
