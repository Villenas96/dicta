# Instalador de una línea para Windows. En PowerShell:
#   irm https://raw.githubusercontent.com/Villenas96/dicta/main/scripts/install-windows.ps1 | iex
# Descarga el instalador de la última versión y lo ejecuta (sin permisos de administrador).
$ErrorActionPreference = 'Stop'
$url = 'https://github.com/Villenas96/dicta/releases/latest/download/Dicta-Setup.exe'
$out = Join-Path $env:TEMP 'Dicta-Setup.exe'
Write-Host '→ Descargando Dicta…'
Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing
Write-Host '→ Instalando…'
Start-Process -FilePath $out -ArgumentList '/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait
Write-Host '✔ Dicta instalada. Busca el icono del micrófono junto al reloj.'
