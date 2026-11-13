#requires -Version 5.1
[CmdletBinding()]
param(
    # Optional /24 override, for example 192.168.1. Otherwise use the active IPv4 subnet.
    [ValidatePattern('^(\d{1,3}\.){2}\d{1,3}$')]
    [string]$Subnet,
    [ValidateRange(1, 65535)]
    [int]$SshPort = 22,
    [ValidateRange(100, 5000)]
    [int]$TimeoutMs = 500
)

$ErrorActionPreference = 'Stop'
if (-not $Subnet) {
    $routes = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' |
        Where-Object { $_.NextHop -ne '0.0.0.0' } |
        ForEach-Object {
            $ipInterface = Get-NetIPInterface -AddressFamily IPv4 -InterfaceIndex $_.InterfaceIndex
            [pscustomobject]@{ Index = $_.InterfaceIndex; Metric = $_.RouteMetric + $ipInterface.InterfaceMetric }
        } | Sort-Object Metric)
    if (-not $routes.Count) { throw 'No active IPv4 default route. Connect to your LAN or specify -Subnet 192.168.1.' }
    $address = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $routes[0].Index |
        Where-Object { $_.AddressState -eq 'Preferred' -and $_.IPAddress -notlike '169.254.*' } |
        Select-Object -First 1
    if (-not $address) { throw 'No IPv4 address found on the active interface.' }
    if ($address.PrefixLength -ne 24) {
        throw "Your active network uses /$($address.PrefixLength). Specify the /24 range to scan, for example -Subnet 192.168.1."
    }
    $Subnet = $address.IPAddress.Substring(0, $address.IPAddress.LastIndexOf('.'))
}
foreach ($octet in $Subnet.Split('.')) {
    if ([int]$octet -gt 255) { throw 'Subnet octets must be between 0 and 255.' }
}

Write-Host "Scanning $Subnet.1-254 for ping replies and SSH on port $SshPort..."
Write-Host 'An open SSH port is a candidate; it does not prove the device is a Raspberry Pi.'

$found = [System.Collections.Generic.List[object]]::new()
# Bounded batches avoid hundreds of simultaneous sockets; SSH probes also find devices blocking ping.
for ($first = 1; $first -le 254; $first += 32) {
    $probes = @()
    try {
        for ($number = $first; $number -le [Math]::Min($first + 31, 254); $number++) {
            $ip = "$Subnet.$number"
            $ping = [System.Net.NetworkInformation.Ping]::new()
            $client = [System.Net.Sockets.TcpClient]::new()
            $probes += [pscustomobject]@{
                IPAddress = $ip
                Ping = $ping
                PingTask = $ping.SendPingAsync($ip, $TimeoutMs)
                Client = $client
                ConnectTask = $client.ConnectAsync($ip, $SshPort)
            }
        }
        # All probes in this batch share a single deadline.
        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
        foreach ($probe in $probes) {
            $remaining = [int][Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            if ($remaining -gt 0) {
                try { $null = $probe.ConnectTask.Wait($remaining) } catch { }
            }
            $remaining = [int][Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            if ($remaining -gt 0) {
                try { $null = $probe.PingTask.Wait($remaining) } catch { }
            }
            $sshOpen = $probe.ConnectTask.Status -eq 'RanToCompletion' -and $probe.Client.Connected
            $pingReply = $probe.PingTask.Status -eq 'RanToCompletion' -and
                $probe.PingTask.Result.Status -eq [System.Net.NetworkInformation.IPStatus]::Success
            if ($sshOpen -or $pingReply) {
                $found.Add([pscustomobject]@{
                    IPAddress = $probe.IPAddress
                    Ping = $pingReply
                    SSH = $sshOpen
                })
            }
        }
    }
    finally {
        foreach ($probe in $probes) {
            $probe.Client.Dispose()
            $probe.Ping.Dispose()
        }
    }
}

if (-not $found.Count) {
    Write-Host 'No responding devices found. Check the subnet, Pi power, Wi-Fi isolation, or try -TimeoutMs 1500.'
    return
}
$found | Format-Table -AutoSize | Out-Host
$candidates = @($found | Where-Object SSH)
if ($candidates.Count) {
    Write-Host 'SSH candidates (replace YOUR_USERNAME with your Pi account):'
    foreach ($candidate in $candidates) {
        Write-Host "  ssh -p $SshPort YOUR_USERNAME@$($candidate.IPAddress)"
    }
    Write-Host 'After signing in, run hostname and cat /proc/device-tree/model to identify the Pi.'
}
else {
    Write-Host 'Devices responded, but no SSH port was open. SSH may need to be enabled on the Pi.'
}
