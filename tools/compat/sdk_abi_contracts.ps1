param(
    [string]$Out = "reports/compat/abi-contracts"
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

function Rel([string]$root, [string]$path) {
    $full = [IO.Path]::GetFullPath($path)
    $base = [IO.Path]::GetFullPath($root).TrimEnd("\", "/")
    if ($full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
        return $full.Substring($base.Length).TrimStart("\", "/").Replace("\", "/")
    }
    return $full.Replace("\", "/")
}

function MatchFiles([string]$root, [string]$pattern) {
    $wc = [System.Management.Automation.WildcardPattern]::new($pattern.Replace("\", "/"), [System.Management.Automation.WildcardOptions]::IgnoreCase)
    @($script:AllFiles | Where-Object { $wc.IsMatch($_.rel) } | ForEach-Object { $_.file })
}

function ReadAllText($files) {
    $parts = @()
    foreach ($file in $files) {
        $parts += [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($file.FullName))
    }
    return ($parts -join "`n")
}

function AddResult($rows, [string]$vendor, [string]$kind, [string]$item, [bool]$pass, [string]$evidence, [string]$reason, [switch]$Blocked) {
    $rows.Add([pscustomobject]@{
        vendor = $vendor
        kind = $kind
        item = $item
        verdict = if ($Blocked) { "blocked" } elseif ($pass) { "pass" } else { "fail" }
        evidence = $evidence
        reason = $reason
    }) | Out-Null
}

function TokenPresent([string]$text, [string]$token) {
    return $text.IndexOf($token, [StringComparison]::Ordinal) -ge 0
}

function TokensOrdered([string]$text, [string[]]$tokens) {
    $cursor = -1
    foreach ($token in $tokens) {
        $idx = $text.IndexOf($token, [Math]::Max(0, $cursor), [StringComparison]::Ordinal)
        if ($idx -lt 0) { return $false }
        $cursor = $idx + $token.Length
    }
    return $true
}

function RenderMarkdown($rows) {
    $lines = @("# Native SDK ABI/Header Contracts", "")
    $lines += "| Vendor | Kind | Item | Verdict | Evidence | Reason |"
    $lines += "|---|---|---|---|---|---|"
    foreach ($row in $rows) {
        $lines += "| $($row.vendor) | $($row.kind) | ``$($row.item)`` | $($row.verdict) | $($row.evidence) | $($row.reason) |"
    }
    $lines -join "`n"
}

$root = RepoRoot
$outPath = if ([IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path $root $Out }
$script:AllFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
    $rel = Rel $root $_.FullName
    if (-not $rel.StartsWith(".claude/") -and -not $rel.StartsWith(".git/") -and -not $rel.StartsWith("target/")) {
        [pscustomobject]@{ file = $_; rel = $rel }
    }
} | Where-Object { $_ })

$contracts = @(
    @{
        vendor = "ZWO"
        headers = @("SDKs/ZWO/**/ASICamera2.h", "SDKs/ZWO/**/EAF_focuser.h", "SDKs/ZWO/**/EFW_filter.h")
        rust = "native/skotiq_native/native/src/vendor/zwo.rs"
        header_symbols = @("ASIGetNumOfConnectedCameras", "ASIGetCameraProperty", "ASIStartExposure", "ASIGetDataAfterExp", "EAFGetNum", "EAFMove", "EFWGetNum", "EFWSetPosition")
        rust_symbols = @("ASIGetNumOfConnectedCameras", "ASIGetCameraProperty", "ASIStartExposure", "ASIGetDataAfterExp", "EAFGetNum", "EAFMove", "EFWGetNum", "EFWSetPosition")
        ordered_structs = @(
            @{ name = "ASICameraInfo"; tokens = @("name: [c_char; 64]", "camera_id: c_int", "max_height: c_long", "max_width: c_long", "is_color_cam: c_int", "bayer_pattern: c_int") }
        )
    },
    @{
        vendor = "Atik"
        headers = @("SDKs/Atik/**/AtikCameras.h", "SDKs/Atik/**/AtikDefs.h")
        rust = "native/skotiq_native/native/src/vendor/atik.rs"
        header_symbols = @("ArtemisDeviceCount", "ArtemisConnect", "ArtemisStartExposure", "ArtemisGetImageData", "ArtemisSetCooling", "ArtemisEFWConnect")
        rust_symbols = @("ArtemisDeviceCount", "ArtemisConnect", "ArtemisStartExposure", "ArtemisGetImageData", "ArtemisSetCooling", "ArtemisDeviceHasFilterWheel")
        ordered_structs = @(
            @{ name = "ArtemisProperties"; tokens = @("protocol: c_int", "pixels_x: c_int", "pixels_y: c_int", "pixel_microns_x: c_float", "pixel_microns_y: c_float", "camera_flags: c_int") }
        )
    },
    @{
        vendor = "SVBONY"
        headers = @("SDKs/SVBony/**/*.h", "SDKs/SVBONY/**/*.h")
        rust = "native/skotiq_native/native/src/vendor/svbony.rs"
        header_symbols = @("SVBGetNumOfConnectedCameras", "SVBGetCameraProperty", "SVBOpenCamera", "SVBStartVideoCapture", "SVBGetVideoData")
        rust_symbols = @("SVBGetNumOfConnectedCameras", "SVBGetCameraProperty", "SVBOpenCamera", "SVBStartVideoCapture", "SVBGetVideoData")
        ordered_structs = @()
    },
    @{
        vendor = "Player One"
        headers = @("SDKs/PlayerOne/**/PlayerOneCamera.h")
        rust = "native/skotiq_native/native/src/vendor/player_one.rs"
        header_symbols = @("POAGetCameraCount", "POAGetCameraProperties", "POAOpenCamera", "POAStartExposure", "POAImageReady", "POAGetImageData")
        rust_symbols = @("POAGetCameraCount", "POAGetCameraProperties", "POAOpenCamera", "POAStartExposure", "POAImageReady", "POAGetImageData")
        ordered_structs = @(
            @{ name = "POACameraProperties"; tokens = @("camera_model_name: [c_char; 256]", "user_custom_id: [c_char; 16]", "camera_id: c_int", "max_width: c_int", "max_height: c_int", "bit_depth: c_int", "is_color_camera: c_int", "is_has_st4_port: c_int", "is_has_cooler: c_int") }
        )
    },
    @{
        vendor = "QHYCCD"
        headers = @("SDKs/QHY/**/qhyccd.h", "SDKs/QHY/**/qhyccdstruct.h")
        rust = "native/skotiq_native/native/src/vendor/qhy.rs"
        header_symbols = @("InitQHYCCDResource", "ScanQHYCCD", "OpenQHYCCD", "GetQHYCCDChipInfo", "ExpQHYCCDSingleFrame", "GetQHYCCDSingleFrame", "IsQHYCCDCFWPlugged")
        rust_symbols = @("InitQHYCCDResource", "ScanQHYCCD", "OpenQHYCCD", "GetQHYCCDChipInfo", "ExpQHYCCDSingleFrame", "GetQHYCCDSingleFrame", "IsQHYCCDCFWPlugged")
        enum_values = @(
            @{ name = "QhyControl"; tokens = @("CONTROL_GAIN = 6", "CONTROL_OFFSET = 7", "CONTROL_EXPOSURE = 8", "CONTROL_CURTEMP = 14", "CONTROL_COOLER = 18", "CAM_BIN2X2MODE = 22", "CAM_16BITS = 35", "CAM_IS_COLOR = 59") }
        )
        ordered_structs = @()
    },
    @{
        vendor = "ToupTek/Altair/OGMA"
        headers = @("SDKs/Touptek/**/ogmacam.h", "SDKs/ToupTek/**/ogmacam.h")
        rust = "native/skotiq_native/native/src/vendor/touptek.rs"
        header_symbols = @("Ogmacam_EnumV2", "Ogmacam_Open", "Ogmacam_StartPullModeWithCallback", "Ogmacam_PullImage", "Ogmacam_put_Option", "Ogmacam_get_Temperature")
        rust_symbols = @("sym(""EnumV2"")", "sym(""OpenByIndex"")", "sym(""PullImageV3"")", "sym(""put_Option"")", "sym(""get_Temperature"")")
        ordered_structs = @(
            @{ name = "OgmacamDeviceV2"; tokens = @("displayname: [u16; 64]", "id: [u16; 64]", "model: *const OgmacamModelV2") }
        )
    },
    @{
        vendor = "Moravian"
        headers = @("SDKs/Moravian/**/*.h")
        rust = "native/skotiq_native/native/src/vendor/moravian.rs"
        header_symbols = @("Enumerate", "Initialize", "Open", "BeginExposure", "GetImage", "SetTemperature", "SetFilter")
        rust_symbols = @("Enumerate", "Initialize", "Open", "BeginExposure", "GetImage", "SetTemperature", "SetFilter")
        ordered_structs = @()
    },
    @{
        vendor = "FLI"
        headers = @("SDKs/FLI/**/libfli.h")
        rust = "native/skotiq_native/native/src/vendor/fli.rs"
        header_symbols = @("FLIOpen", "FLIExposeFrame", "FLIGrabRow", "FLISetTemperature", "FLISetFilterPos", "FLIStepMotor")
        rust_symbols = @("FLIOpen", "FLIExposeFrame", "FLIGrabRow", "FLISetTemperature", "FLISetFilterPos", "FLIStepMotor")
        ordered_structs = @()
    },
    @{
        vendor = "Fujifilm"
        headers = @("SDKs/Fujifilm/**/XAPI.H", "SDKs/Fujifilm/**/XAPI.h")
        rust = "native/skotiq_native/native/src/vendor/fujifilm.rs"
        header_symbols = @("XSDK_Init", "XSDK_Detect", "XSDK_OpenEx", "XSDK_Release", "XSDK_ReadImageInfo", "XSDK_ReadImage")
        rust_symbols = @("XSDK_Init", "XSDK_Detect", "XSDK_OpenEx", "XSDK_Release", "XSDK_ReadImageInfo", "XSDK_ReadImage")
        ordered_structs = @(
            @{ name = "XsdkCameraList"; tokens = @("str_product: [c_char; 256]", "str_serial_no: [c_char; 256]", "str_ip_address: [c_char; 256]", "str_framework: [c_char; 256]", "b_valid: bool") }
        )
    }
)

$rows = [System.Collections.Generic.List[object]]::new()

foreach ($contract in $contracts) {
    $headers = @()
    foreach ($pattern in $contract.headers) { $headers += MatchFiles $root $pattern }
    $headers = @($headers | Sort-Object FullName -Unique)
    # Vendor SDK headers live under SDKs/ which is gitignored, so they are absent
    # on hosts without the vendor SDKs installed (e.g. CI runners). Without the
    # header we cannot verify its ABI surface — that is BLOCKED (evidence
    # unavailable), not a FAIL. A fail must mean the SDK is present but its
    # symbols/struct layout drifted from what the Rust FFI expects.
    $headersPresent = $headers.Count -gt 0
    $headerEvidence = if ($headersPresent) { (($headers | Select-Object -First 3 | ForEach-Object { Rel $root $_.FullName }) -join ", ") } else { "" }
    AddResult $rows $contract.vendor "sdk-header" "header files" $headersPresent $headerEvidence "required SDK header evidence is present" -Blocked:(-not $headersPresent)

    $rustPath = Join-Path $root $contract.rust
    $rustPresent = Test-Path $rustPath
    $rustEvidence = if ($rustPresent) { $contract.rust } else { "" }
    AddResult $rows $contract.vendor "rust-wrapper" $contract.rust $rustPresent $rustEvidence "production Rust wrapper is present"

    $headerText = if ($headers.Count -gt 0) { ReadAllText $headers } else { "" }
    $rustText = if ($rustPresent) { [IO.File]::ReadAllText($rustPath) } else { "" }

    foreach ($symbol in $contract.header_symbols) {
        AddResult $rows $contract.vendor "header-symbol" $symbol (TokenPresent $headerText $symbol) $headerEvidence "vendor header declares required API surface" -Blocked:(-not $headersPresent)
    }
    foreach ($symbol in $contract.rust_symbols) {
        AddResult $rows $contract.vendor "rust-symbol-load" $symbol (TokenPresent $rustText $symbol) $contract.rust "Rust FFI loader references the same SDK symbol"
    }
    foreach ($shape in @($contract.ordered_structs)) {
        AddResult $rows $contract.vendor "rust-struct-order" $shape.name (TokensOrdered $rustText $shape.tokens) $contract.rust "repr(C) wrapper keeps expected field order"
    }
    foreach ($shape in @($contract.enum_values)) {
        foreach ($token in $shape.tokens) {
            AddResult $rows $contract.vendor "rust-enum-value" "$($shape.name).$token" (TokenPresent $rustText $token) $contract.rust "Rust enum discriminant matches SDK header expectation"
        }
    }
}

New-Item -ItemType Directory -Force -Path $outPath | Out-Null
$rows | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 (Join-Path $outPath "abi-contracts.json")
RenderMarkdown $rows | Set-Content -Encoding UTF8 (Join-Path $outPath "abi-contracts.md")

$failed = @($rows | Where-Object { $_.verdict -eq "fail" })
$blocked = @($rows | Where-Object { $_.verdict -eq "blocked" })
$passed = $rows.Count - $failed.Count - $blocked.Count
Write-Host "Native SDK ABI/header contracts: $passed passed, $($failed.Count) failed, $($blocked.Count) blocked (SDK headers absent)"
if ($failed.Count -gt 0) {
    foreach ($row in ($failed | Select-Object -First 20)) {
        Write-Host "FAIL $($row.vendor) $($row.kind) $($row.item): $($row.reason)"
    }
    exit 1
}
