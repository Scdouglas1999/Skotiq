# Allow inbound TCP (HTTP API) and UDP (LAN discovery) for Skotiq remote access.
param(
    [int]$HttpPort = 8080,
    [int]$DiscoveryPort = 45679,
    [string]$TcpRuleName = "Skotiq Remote Access HTTP",
    [string]$UdpRuleName = "Skotiq Remote Access Discovery"
)

function Ensure-Rule {
    param(
        [string]$DisplayName,
        [string]$Protocol,
        [int]$LocalPort
    )
    $existing = Get-NetFirewallRule -DisplayName $DisplayName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "Firewall rule '$DisplayName' already exists."
        return
    }
    New-NetFirewallRule -DisplayName $DisplayName `
        -Direction Inbound `
        -Action Allow `
        -Protocol $Protocol `
        -LocalPort $LocalPort `
        -Profile Private `
        | Out-Null
    Write-Host "Created '$DisplayName' ($Protocol $LocalPort, Private profile)."
}

Ensure-Rule -DisplayName $TcpRuleName -Protocol TCP -LocalPort $HttpPort
Ensure-Rule -DisplayName $UdpRuleName -Protocol UDP -LocalPort $DiscoveryPort

Write-Host "Test from tablet browser: http://<this-pc-lan-ip>:$HttpPort/api/info"
Write-Host "Mobile auto-discovery uses UDP $DiscoveryPort + HTTP $HttpPort."
