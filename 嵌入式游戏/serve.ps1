# 本地静态服务器（PowerShell 5 / .NET Socket，无需 Node 或 Python）
# 用法：在 Trae 终端执行
#   powershell -NoProfile -Command "&([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 'E:\嵌入式游戏\serve.ps1')))"
# 说明：监听所有网卡（IPv4 + IPv6），因此本机用 http://localhost:8000，
#       手机连同一个 Wi-Fi 后用 http://<本机局域网IP>:8000 即可访问真机测试

# 以脚本所在目录作为网站根目录（用脚本块方式加载时 $PSScriptRoot 为空，回退到项目目录）
$root = $PSScriptRoot
if (-not $root) { $root = 'E:\嵌入式游戏' }
$port = 8000
# 端口被占用时可用环境变量覆盖：$env:PORT=8099
if ($env:PORT) { $port = [int]$env:PORT }

# ---- 创建监听 socket（优先双栈，失败则退回 IPv4）----
$socket = $null
try {
  $socket = [System.Net.Sockets.Socket]::new(
    [System.Net.Sockets.AddressFamily]::InterNetworkV6,
    [System.Net.Sockets.SocketType]::Stream,
    [System.Net.Sockets.ProtocolType]::Tcp)
  $socket.DualMode = $true
  $socket.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::IPv6Any, $port))
} catch {
  if ($socket) { $socket.Close() }
  $socket = [System.Net.Sockets.Socket]::new(
    [System.Net.Sockets.AddressFamily]::InterNetwork,
    [System.Net.Sockets.SocketType]::Stream,
    [System.Net.Sockets.ProtocolType]::Tcp)
  $socket.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, $port))
}
$socket.Listen(50)

Write-Host "静态服务器已启动:"
Write-Host "  http://localhost:$port/"
Write-Host "  http://127.0.0.1:$port/"
# 手机真机测试用这个地址（需与本机处于同一个 Wi-Fi）
$lanIps = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Where-Object { $_.IPAddress -notlike '127.*' -and $_.PrefixOrigin -ne 'WellKnown' } |
  Select-Object -ExpandProperty IPAddress
foreach ($ip in $lanIps) {
  Write-Host "  http://${ip}:$port/     <-- 手机浏览器打开这个"
}
Write-Host "  根目录: $root"
Write-Host "停止服务: 在本终端按 Ctrl + C"
Write-Host ""

$mimeMap = @{
  '.html' = 'text/html; charset=utf-8'
  '.htm'  = 'text/html; charset=utf-8'
  '.js'   = 'application/javascript; charset=utf-8'
  '.css'  = 'text/css; charset=utf-8'
  '.json' = 'application/json; charset=utf-8'
  '.png'  = 'image/png'
  '.jpg'  = 'image/jpeg'
  '.jpeg' = 'image/jpeg'
  '.gif'  = 'image/gif'
  '.svg'  = 'image/svg+xml'
  '.ico'  = 'image/x-icon'
  '.wav'  = 'audio/wav'
  '.mp3'  = 'audio/mpeg'
}

while ($true) {
  $conn = $socket.Accept()
  $conn.ReceiveTimeout = 2000   # 浏览器预连接的空闲 socket 2 秒后丢弃，避免阻塞主循环
  try {
    $buf = New-Object byte[] 8192
    $header = ''
    while ($header -notmatch "`r`n`r`n") {
      $n = $conn.Receive($buf)
      if ($n -le 0) { break }
      $header += [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
      if ($header.Length -gt 16384) { break }
    }
    if ($header.Length -eq 0) { $conn.Close(); continue }

    $method = 'GET'
    if ($header -match '(?im)^(GET|HEAD)\s') { $method = $matches[1].ToUpper() }
    $path = '/'
    if ($header -match '(?im)^(?:GET|HEAD)\s+([^\s]+)') { $path = $matches[1] }
    $path = [System.Uri]::UnescapeDataString($path.Split('?')[0].TrimStart('/'))
    if ($path -eq '') { $path = 'index.html' }

    $file = Join-Path $root $path
    if (Test-Path -LiteralPath $file -PathType Leaf) {
      $bytes = [System.IO.File]::ReadAllBytes($file)
      $ext = [System.IO.Path]::GetExtension($file).ToLower()
      $mime = $mimeMap[$ext]
      if (-not $mime) { $mime = 'application/octet-stream' }
      $head = "HTTP/1.1 200 OK`r`nContent-Type: $mime`r`nContent-Length: $($bytes.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
      $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
      $conn.Send($hb) | Out-Null
      if ($method -eq 'GET') { $conn.Send($bytes) | Out-Null }
      Write-Host "200 $method $path"
    } else {
      $body = [System.Text.Encoding]::UTF8.GetBytes('404 Not Found')
      $head = "HTTP/1.1 404 Not Found`r`nContent-Type: text/plain; charset=utf-8`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n"
      $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
      $conn.Send($hb) | Out-Null
      if ($method -eq 'GET') { $conn.Send($body) | Out-Null }
      Write-Host "404 $method $path"
    }
    try { $conn.Shutdown([System.Net.Sockets.SocketShutdown]::Send) } catch {}
    $conn.Close()
  } catch {
    Write-Host "ERR $($_.Exception.Message)"
    try { $conn.Close() } catch {}
  }
}
