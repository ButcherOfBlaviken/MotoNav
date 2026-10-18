$ErrorActionPreference='Stop'
try {
    Write-Host '读取当前整片16MB Flash。已刷MotoNav的设备备份出来就是当前MotoNav，不是原厂固件。'
    $taskPorts=@([IO.Ports.SerialPort]::GetPortNames() | Sort-Object)
    Write-Host ('当前串口：'+($taskPorts -join '、'))
    $taskPort=(Read-Host '输入待备份圆屏的COM号；Q退出').Trim().ToUpperInvariant()
    if($taskPort -eq 'Q'){exit 0}
    if($taskPort -notmatch '^COM[0-9]+$' -or $taskPorts -notcontains $taskPort){throw 'COM号无效。'}
    $taskBackupDir=Join-Path $PSScriptRoot 'backups'
    New-Item -ItemType Directory -Force $taskBackupDir | Out-Null
    $taskOutput=Join-Path $taskBackupDir ('当前Flash-'+$taskPort+'-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.bin')
    & (Join-Path $PSScriptRoot 'tools\esptool.exe') --chip esp32s3 --port $taskPort --baud 460800 --after watchdog-reset read-flash 0x0 0x1000000 $taskOutput
    if($LASTEXITCODE -ne 0){throw '备份未完成。'}
    if((Get-Item -LiteralPath $taskOutput).Length -ne 0x1000000){throw '备份大小不等于16MB。'}
    $taskHasher=[Security.Cryptography.SHA256]::Create()
    try{$taskHash=[BitConverter]::ToString($taskHasher.ComputeHash([IO.File]::ReadAllBytes($taskOutput))).Replace('-','')}
    finally{$taskHasher.Dispose()}
    $taskHash | Set-Content -Encoding ASCII ($taskOutput+'.sha256.txt')
    Write-Host "备份完成：$taskOutput" -ForegroundColor Green
    exit 0
}catch{Write-Host ('备份未完成：'+$_.Exception.Message) -ForegroundColor Red;exit 1}
