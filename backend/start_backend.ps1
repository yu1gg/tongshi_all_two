param(
    [switch]$CheckOnly
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir
$seaweedExecutable = "D:\Users\ASUS\Desktop\windows_amd64\weed.exe"
$seaweedDataDir = "D:\Users\ASUS\Desktop\windows_amd64\seaweed-data"

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Get-UrlStatusCode {
    param([string]$Url)
    try {
        $headers = curl.exe -s -o NUL -w "%{http_code}" $Url
        if ($LASTEXITCODE -eq 0 -and $headers -match "^\d{3}$") {
            return [int]$headers
        }
    } catch {
        return $null
    }
    return $null
}

function Test-FileExists {
    param([string]$Path)
    try {
        return [System.IO.File]::Exists($Path)
    } catch {
        return $false
    }
}

function Exit-WithError {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
    exit 1
}

function Get-PythonRuntime {
    $candidates = @(
        @{ Executable = (Join-Path $scriptDir ".venv\Scripts\python.exe"); PrefixArgs = @(); Display = ".venv" },
        @{ Executable = "C:\Users\$env:USERNAME\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"; PrefixArgs = @(); Display = "codex-runtime" },
        @{ Executable = "C:\Users\$env:USERNAME\AppData\Local\Programs\Python\Launcher\py.exe"; PrefixArgs = @("-3"); Display = "py-launcher" },
        @{ Name = "py"; PrefixArgs = @("-3"); Display = "py" },
        @{ Name = "python"; PrefixArgs = @(); Display = "python" },
        @{ Executable = "C:\Users\$env:USERNAME\AppData\Local\Programs\Python\Python313\python.exe"; PrefixArgs = @(); Display = "Python313" },
        @{ Executable = "C:\Users\$env:USERNAME\AppData\Local\Programs\Python\Python312\python.exe"; PrefixArgs = @(); Display = "Python312" },
        @{ Executable = "C:\Users\$env:USERNAME\AppData\Local\Programs\Python\Python311\python.exe"; PrefixArgs = @(); Display = "Python311" },
        @{ Executable = "C:\Python312\python.exe"; PrefixArgs = @(); Display = "C:\Python312" },
        @{ Executable = "C:\Python311\python.exe"; PrefixArgs = @(); Display = "C:\Python311" }
    )

    foreach ($candidate in $candidates) {
        if ($candidate.ContainsKey("Name")) {
            $command = Get-Command $candidate.Name -ErrorAction SilentlyContinue
            if ($null -ne $command) {
                return [PSCustomObject]@{
                    Executable = $command.Source
                    PrefixArgs = $candidate.PrefixArgs
                    Display    = $candidate.Display
                }
            }
        }

        if ($candidate.ContainsKey("Executable") -and (Test-FileExists $candidate.Executable)) {
            return [PSCustomObject]@{
                Executable = $candidate.Executable
                PrefixArgs = $candidate.PrefixArgs
                Display    = $candidate.Display
            }
        }
    }

    Exit-WithError "Python not found. Make sure py or python is available in PATH."
}

function Invoke-Python {
    param(
        [Parameter(Mandatory = $true)]
        $PythonRuntime,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    & $PythonRuntime.Executable @($PythonRuntime.PrefixArgs + $Arguments) | Out-Host
    return $LASTEXITCODE
}

function Get-EnvMap {
    $envFile = Join-Path $scriptDir ".env"
    if (-not (Test-Path $envFile)) {
        Exit-WithError "backend/.env not found."
    }

    $result = @{}
    foreach ($line in Get-Content $envFile) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
            continue
        }
        if ($trimmed -match "^\s*([A-Za-z0-9_]+)\s*=\s*(.*)\s*$") {
            $key = $matches[1]
            $value = $matches[2].Trim()
            $result[$key] = $value
        }
    }

    return $result
}

function Test-S3Endpoint {
    param([string]$Endpoint)

    if ([string]::IsNullOrWhiteSpace($Endpoint)) {
        Exit-WithError "S3_ENDPOINT is missing while STORAGE_BACKEND=s3."
    }

    $statusCode = Get-UrlStatusCode $Endpoint
    if ($statusCode -in 200, 204, 301, 302, 307, 308, 403, 405) {
        return $true
    }

    return $false
}

function Start-SeaweedFS {
    if (-not (Test-FileExists $seaweedExecutable)) {
        Exit-WithError "SeaweedFS executable not found: $seaweedExecutable"
    }

    if (-not (Test-Path $seaweedDataDir)) {
        New-Item -ItemType Directory -Path $seaweedDataDir -Force | Out-Null
    }

    Write-Info "Starting SeaweedFS mini..."
    $seaweedCommand = @"
Remove-Item Env:debug -ErrorAction SilentlyContinue
Remove-Item Env:DEBUG -ErrorAction SilentlyContinue
$env:AWS_ACCESS_KEY_ID='test'
$env:AWS_SECRET_ACCESS_KEY='test'
& '$seaweedExecutable' mini -dir '$seaweedDataDir' -bucket 'tongshi-public,tongshi-private'
"@

    Start-Process `
        -FilePath "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList @("-NoExit", "-Command", $seaweedCommand) `
        -WorkingDirectory (Split-Path -Parent $seaweedExecutable) `
        -WindowStyle Normal

    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 2
        if (Test-S3Endpoint -Endpoint "http://localhost:8333") {
            Write-Ok "SeaweedFS S3 endpoint started: http://localhost:8333"
            return
        }
    }

    Exit-WithError "SeaweedFS did not become ready on http://localhost:8333"
}

function Test-BackendPort {
    $listenConn = Get-NetTCPConnection -LocalPort 8050 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $listenConn) {
        return $false
    }

    try {
        $health = Invoke-RestMethod -Uri "http://127.0.0.1:8050/health" -TimeoutSec 3
        if ($health.status -eq "ok") {
            Write-Ok "Backend already running at http://127.0.0.1:8050"
            return $true
        }
    } catch {
        Exit-WithError "Port 8050 is occupied by another process."
    }

    Exit-WithError "Port 8050 is occupied and health check failed."
}

Write-Info "Checking backend environment..."

$pythonRuntime = Get-PythonRuntime
Write-Ok ("Python command found: {0}" -f $pythonRuntime.Display)

$dependencyCheck = Invoke-Python -PythonRuntime $pythonRuntime -Arguments @(
    "-c",
    "import fastapi, uvicorn, pymysql, dotenv, boto3; print('deps ok')"
)
if ($dependencyCheck -ne 0) {
    Exit-WithError "Dependencies are incomplete. Run pip install -r requirements.txt first."
}
Write-Ok "Dependency check passed"

$envMap = Get-EnvMap
$storageBackend = "local"
if ($envMap.ContainsKey("STORAGE_BACKEND")) {
    $storageBackend = $envMap["STORAGE_BACKEND"].ToLowerInvariant()
}

Write-Info "Checking database connection..."
$dbCheck = Invoke-Python -PythonRuntime $pythonRuntime -Arguments @("database_setup.py", "--check")
if ($dbCheck -ne 0) {
    Write-Info "Database check failed. Trying database_setup.py ..."
    $dbInit = Invoke-Python -PythonRuntime $pythonRuntime -Arguments @("database_setup.py")
    if ($dbInit -ne 0) {
        Exit-WithError "Database initialization failed."
    }
    Write-Ok "Database initialized"
} else {
    Write-Ok "Database connection ok"
}

if ($storageBackend -eq "s3") {
    Write-Info "Checking SeaweedFS S3 endpoint..."
    $endpoint = ""
    if ($envMap.ContainsKey("S3_ENDPOINT")) {
        $endpoint = $envMap["S3_ENDPOINT"]
    }

    if (-not (Test-S3Endpoint -Endpoint $endpoint)) {
        Write-Info "SeaweedFS S3 endpoint is unavailable. Trying to start it..."
        Start-SeaweedFS
        if (-not (Test-S3Endpoint -Endpoint $endpoint)) {
            Exit-WithError "Cannot reach SeaweedFS S3 endpoint: $endpoint"
        }
    }
    Write-Ok "SeaweedFS S3 endpoint reachable: $endpoint"
}

if (Test-BackendPort) {
    if ($CheckOnly) {
        Write-Ok "Check complete"
        exit 0
    }
    Write-Info "Backend is already running. Skip duplicate start."
    exit 0
}

if ($CheckOnly) {
    Write-Ok "Check complete. Backend is not running."
    exit 0
}

Write-Host ""
Write-Host "Starting backend..." -ForegroundColor Yellow
Write-Host "Docs:    http://127.0.0.1:8050/docs"
Write-Host "Health:  http://127.0.0.1:8050/health"
Write-Host ""

& $pythonRuntime.Executable @($pythonRuntime.PrefixArgs + @("main.py"))
exit $LASTEXITCODE
