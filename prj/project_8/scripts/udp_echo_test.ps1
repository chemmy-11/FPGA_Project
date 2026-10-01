# udp_echo_test.ps1  -  project_8 数据级判据(不依赖网络调试助手)
#   随机源端口发 UDP -> 板卡 192.168.1.10:1234
#   新版设计会把回显发回"发送方源端口", 故本 socket 能直接收到并比对
$dst = '192.168.1.10'
$port = 1234
$u = New-Object System.Net.Sockets.UdpClient
$u.Client.ReceiveTimeout = 2000
$u.Connect($dst, $port)
$local = $u.Client.LocalEndPoint.Port
Write-Output ("local ephemeral port = " + $local + "  ->  " + $dst + ":" + $port)
$lengths = @(4, 26, 29, 33, 40, 100, 200)
$ok = 0; $total = 0
foreach ($n in $lengths) {
  $total++
  $sb = New-Object System.Text.StringBuilder
  while ($sb.Length -lt $n) { [void]$sb.Append("P8-AURORA-64B66B-") }
  $s = $sb.ToString().Substring(0, $n)
  $p = [System.Text.Encoding]::ASCII.GetBytes($s)
  $null = $u.Send($p, $p.Length)
  try {
    $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
    $rx = $u.Receive([ref]$ep)
    $rxs = [System.Text.Encoding]::ASCII.GetString($rx)
    if ($rxs -eq $s) { $ok++; Write-Output ("  L=" + $n.ToString().PadLeft(4) + "  send " + $p.Length + "B  recv " + $rx.Length + "B  MATCH   from " + $ep.ToString()) }
    else { Write-Output ("  L=" + $n.ToString().PadLeft(4) + "  send " + $p.Length + "B  recv " + $rx.Length + "B  MISMATCH  rx='" + $rxs + "'") }
  } catch {
    Write-Output ("  L=" + $n.ToString().PadLeft(4) + "  send " + $p.Length + "B  NO ECHO (timeout)")
  }
  Start-Sleep -Milliseconds 400
}
$u.Close()
Write-Output ("RESULT: " + $ok + "/" + $total + " echoed byte-identical")
