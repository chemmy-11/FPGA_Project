# traffic.ps1 - 从随机源端口向板卡 192.168.1.10:1234 发 UDP，回包会落到 PC:1234
$ErrorActionPreference = 'Continue'
$dst = '192.168.1.10'
$port = 1234
$u = New-Object System.Net.Sockets.UdpClient
$u.Client.ReceiveTimeout = 1500
$u.Connect($dst, $port)
Write-Output ("local port = " + $u.Client.LocalEndPoint.Port)
$payload = [System.Text.Encoding]::ASCII.GetBytes('P8-AURORA-ARPTEST-0001')
for ($i=1; $i -le 4; $i++) {
    $null = $u.Send($payload, $payload.Length)
    Write-Output ("sent #" + $i + " " + $payload.Length + " bytes")
    Start-Sleep -Milliseconds 500
}
$u.Close()
Write-Output 'TRAFFIC_DONE'
