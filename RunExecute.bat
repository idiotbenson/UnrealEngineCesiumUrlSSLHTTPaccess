@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "SCRIPT_DIR=%~dp0"
cd /d "%SCRIPT_DIR%"

set "CACERT_URL=https://curl.se/ca/cacert.pem"
set "AMAZON_URL=https://www.amazontrust.com/repository/AmazonRootCA1.cer"
set "STARFIELD_URL=https://www.amazontrust.com/repository/SFSRootCAG2.cer"
set "TARGET_URL=https://data1.map.gov.hk/api/3d-data/3dtiles/f2/tileset.json?key=3967f8f365694e0798af3e7678509421"
set "SITE_HOST=data1.map.gov.hk"
set "WORK_DIR=%TEMP%\setup_certs_%RANDOM%_%RANDOM%"
set "FATAL_ERROR=0"

echo ================================================
echo   Certificate Setup and Verification Tool
echo ================================================
echo.
echo   Official Certificate Sources:
echo   [1] cacert.pem (Mozilla CA Bundle)
echo       %CACERT_URL%
echo   [2] Amazon Root CA 1
echo       %AMAZON_URL%
echo   [3] Starfield Services Root Certificate Authority - G2
echo       %STARFIELD_URL%
echo       (officially hosted by Amazon Trust Services)
echo.

net session >nul 2>&1
if errorlevel 1 (
    echo Requesting administrator privileges...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

mkdir "%WORK_DIR%" >nul 2>&1

echo [Step 1/5] Checking local `cacert.pem`...
call :ensure_cacert
if errorlevel 1 goto :fatal

echo.
echo [Step 2/5] Checking `AmazonRootCA1.cer` and Windows certificate store...
call :ensure_root_cert "Amazon Root CA 1" "AmazonRootCA1.cer" "%AMAZON_URL%"
if errorlevel 1 goto :fatal

echo.
echo [Step 3/5] Checking `SFSRootCAG2.cer` and Windows certificate store...
call :ensure_root_cert "Starfield Services Root Certificate Authority - G2" "SFSRootCAG2.cer" "%STARFIELD_URL%"
if errorlevel 1 goto :fatal

echo.
echo [Step 4/5] Adding `%SITE_HOST%` certificate chain into `cacert.pem`...
call :append_site_chain
if errorlevel 1 (
    echo   [WARN] Could not append the site certificate chain. Continuing to curl...
)

echo.
echo [Step 5/5] Executing curl request...
where curl.exe >nul 2>&1
if errorlevel 1 (
    echo   [FAIL] curl.exe not found in PATH.
    goto :fatal
)

curl.exe --cacert "cacert.pem" "%TARGET_URL%"
set "CURL_RESULT=%ERRORLEVEL%"
echo.
if "%CURL_RESULT%"=="0" (
    echo [SUCCESS] Request completed successfully.
) else (
    echo [FAIL] curl returned error code %CURL_RESULT%.
)
goto :end

:ensure_cacert
if exist "cacert.pem" (
    findstr /c:"-----BEGIN CERTIFICATE-----" "cacert.pem" >nul 2>&1
    if not errorlevel 1 (
        echo   [OK] `cacert.pem` exists and looks valid.
        exit /b 0
    )
    echo   Existing `cacert.pem` looks invalid. Re-downloading...
)
echo   Source: %CACERT_URL%
call :download_file "%CACERT_URL%" "%SCRIPT_DIR%cacert.pem"
if errorlevel 1 (
    echo   [FAIL] Could not download `cacert.pem`.
    exit /b 1
)
findstr /c:"-----BEGIN CERTIFICATE-----" "cacert.pem" >nul 2>&1
if errorlevel 1 (
    echo   [FAIL] Downloaded `cacert.pem` is not valid.
    exit /b 1
)
echo   [DONE] `cacert.pem` downloaded successfully.
exit /b 0

:ensure_root_cert
set "CERT_NAME=%~1"
set "CERT_FILE=%SCRIPT_DIR%%~2"
set "CERT_URL=%~3"
set "EXPORTED_CERT=%WORK_DIR%\export_%RANDOM%_%RANDOM%.cer"

REM First check if already installed in Windows certificate store
call :get_cert_from_store_by_subject "!CERT_NAME!" "!EXPORTED_CERT!"
if not errorlevel 1 (
    echo   [OK] Already installed in Windows certificate store.
    set "CERT_FILE=!EXPORTED_CERT!"
    goto :ensure_cacert_pem
)

REM Not in store - need to download and install
if exist "!CERT_FILE!" (
    echo   [OK] Local file found: %~2
) else (
    echo   Downloading official certificate for !CERT_NAME!...
    echo   URL: !CERT_URL!
    call :download_file "!CERT_URL!" "!CERT_FILE!"
    if errorlevel 1 (
        echo   [FAIL] Could not download %~2.
        exit /b 1
    )
    echo   [DONE] Downloaded %~2
)

call :get_cert_thumbprint "!CERT_FILE!"
if errorlevel 1 (
    echo   Existing %~2 is invalid. Re-downloading from official source...
    call :download_file "!CERT_URL!" "!CERT_FILE!"
    if errorlevel 1 (
        echo   [FAIL] Could not download a valid copy of %~2.
        exit /b 1
    )
    call :get_cert_thumbprint "!CERT_FILE!"
    if errorlevel 1 (
        echo   [FAIL] Could not read certificate thumbprint from %~2.
        exit /b 1
    )
)
echo   Certificate thumbprint: !CURRENT_THUMBPRINT!

echo   Installing into Windows Root store...
certutil -addstore -f Root "!CERT_FILE!" >nul 2>&1
if errorlevel 1 (
    echo   [FAIL] Installation into Windows Root store failed.
    exit /b 1
)
echo   [DONE] Installed into Windows Root store.

:ensure_cacert_pem
call :pem_has_thumbprint "%SCRIPT_DIR%cacert.pem" "!CURRENT_THUMBPRINT!"
if errorlevel 1 (
    echo   Adding !CERT_NAME! to `cacert.pem`...
    call :append_cert_to_pem "!CERT_FILE!" "!CERT_NAME!"
    if errorlevel 1 (
        echo   [FAIL] Could not append !CERT_NAME! to `cacert.pem`.
        exit /b 1
    )
    echo   [DONE] Added to `cacert.pem`.
) else (
    echo   [OK] Already present in `cacert.pem`.
)

REM Only remove temp exported cert from WORK_DIR, never delete script dir certs
if not "!CERT_FILE:%WORK_DIR%=!"=="!CERT_FILE!" del "!CERT_FILE!" >nul 2>&1
exit /b 0

:append_site_chain
powershell -NoProfile -Command ^
  "$hostName='%SITE_HOST%';" ^
  "$workDir='%WORK_DIR%';" ^
  "$tcp = New-Object System.Net.Sockets.TcpClient($hostName, 443);" ^
  "$ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false, ({$true}));" ^
  "$ssl.AuthenticateAsClient($hostName);" ^
  "$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $ssl.RemoteCertificate;" ^
  "$chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain;" ^
  "$chain.ChainPolicy.RevocationMode = 'NoCheck';" ^
  "[void]$chain.Build($cert);" ^
  "$i = 0;" ^
  "foreach ($element in $chain.ChainElements) {" ^
  "  [System.IO.File]::WriteAllBytes((Join-Path $workDir ('chain_' + $i + '.cer')), $element.Certificate.RawData);" ^
  "  $i++" ^
  "}" ^
  "$ssl.Dispose();" ^
  "$tcp.Close();" ^
  "if ($i -eq 0) { exit 1 }"
if errorlevel 1 exit /b 1

set "CHAIN_INDEX=0"
:site_loop
if not exist "%WORK_DIR%\chain_!CHAIN_INDEX!.cer" goto :site_done
call :get_cert_thumbprint "%WORK_DIR%\chain_!CHAIN_INDEX!.cer"
if errorlevel 1 (
    set /a CHAIN_INDEX+=1
    goto :site_loop
)
call :pem_has_thumbprint "%SCRIPT_DIR%cacert.pem" "!CURRENT_THUMBPRINT!"
if errorlevel 1 (
    echo   Adding site chain certificate !CHAIN_INDEX!...
    call :append_cert_to_pem "%WORK_DIR%\chain_!CHAIN_INDEX!.cer" "%SITE_HOST% chain certificate !CHAIN_INDEX!"
    if not errorlevel 1 echo   [DONE] Site chain certificate !CHAIN_INDEX! added.
) else (
    echo   [OK] Site chain certificate !CHAIN_INDEX! already present.
)
set /a CHAIN_INDEX+=1
goto :site_loop

:site_done
echo   [DONE] Site certificate chain processing finished.
exit /b 0

:download_file
set "DL_URL=%~1"
set "DL_OUT=%~2"
if exist "!DL_OUT!" del /f /q "!DL_OUT!" >nul 2>&1
powershell -NoProfile -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri $env:DL_URL -OutFile $env:DL_OUT -UseBasicParsing"
if exist "!DL_OUT!" exit /b 0
exit /b 1

:get_cert_from_store_by_subject
set "CURRENT_THUMBPRINT="
for /f "usebackq delims=" %%t in (`powershell -NoProfile -Command "& { param($subj,$out) $c=Get-ChildItem Cert:\LocalMachine\Root,Cert:\CurrentUser\Root -ErrorAction SilentlyContinue ^| Where-Object { $_.Subject -like ('*'+$subj+'*') } ^| Select-Object -First 1; if($c){$c.Thumbprint.ToUpper();[IO.File]::WriteAllBytes($out,$c.RawData)} }" -ArgumentList "%~1","%~2"`) do set "CURRENT_THUMBPRINT=%%t"
if not defined CURRENT_THUMBPRINT exit /b 1
if not exist "%~2" exit /b 1
exit /b 0

:get_cert_thumbprint
set "CURRENT_THUMBPRINT="
for /f "usebackq delims=" %%I in (`powershell -NoProfile -Command "& { param($p) $c=[System.Security.Cryptography.X509Certificates.X509Certificate2]::new($p); $c.Thumbprint.ToUpper() }" -ArgumentList "%~1"`) do set "CURRENT_THUMBPRINT=%%I"
if not defined CURRENT_THUMBPRINT exit /b 1
exit /b 0

:pem_has_thumbprint
powershell -NoProfile -Command ^
  "$pemPath='%~1';" ^
  "$thumb='%~2';" ^
  "$content = Get-Content -Raw -Path $pemPath;" ^
  "$matches = [regex]::Matches($content, '-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----', [System.Text.RegularExpressions.RegexOptions]::Singleline);" ^
  "foreach ($match in $matches) {" ^
  "  $base64 = ($match.Value -replace '-----BEGIN CERTIFICATE-----', '' -replace '-----END CERTIFICATE-----', '' -replace '\s', '');" ^
  "  try {" ^
  "    $bytes = [Convert]::FromBase64String($base64);" ^
  "    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @(,$bytes);" ^
  "    if ($cert.Thumbprint.ToUpper() -eq $thumb) { exit 0 }" ^
  "  } catch {}" ^
  "}" ^
  "exit 1"
exit /b %ERRORLEVEL%

:append_cert_to_pem
set "APPEND_CERT_FILE=%~1"
set "APPEND_CERT_NAME=%~2"
set "TEMP_PEM=%WORK_DIR%\append_%RANDOM%_%RANDOM%.pem"
certutil -encode "!APPEND_CERT_FILE!" "!TEMP_PEM!" >nul 2>&1
if errorlevel 1 exit /b 1
>> "%SCRIPT_DIR%cacert.pem" echo.
>> "%SCRIPT_DIR%cacert.pem" echo # !APPEND_CERT_NAME!
type "!TEMP_PEM!" >> "%SCRIPT_DIR%cacert.pem"
del "!TEMP_PEM!" >nul 2>&1
exit /b 0

:fatal
set "FATAL_ERROR=1"
echo.
echo [FAIL] Script stopped because a required step failed.
goto :end

:end
echo.
set "EXE_TO_RUN="
for %%e in ("%SCRIPT_DIR%*.exe") do (
    set "EXE_TO_RUN=%%e"
    goto :run_exe
)
:run_exe
if "%FATAL_ERROR%"=="1" (
    echo Skipping .exe launch due to previous errors.
) else if defined EXE_TO_RUN (
    echo Launching !EXE_TO_RUN!...
    start "" "!EXE_TO_RUN!"
) else (
    echo No .exe file found in script folder.
)
echo.
echo ================================================
echo   Script complete.
echo ================================================
if exist "%WORK_DIR%" rmdir /s /q "%WORK_DIR%" >nul 2>&1
if "%FATAL_ERROR%"=="0" (
    if exist "%SCRIPT_DIR%AmazonRootCA1.cer" (
        del /f /q "%SCRIPT_DIR%AmazonRootCA1.cer" >nul 2>&1
        echo   Removed downloaded AmazonRootCA1.cer
    )
    if exist "%SCRIPT_DIR%SFSRootCAG2.cer" (
        del /f /q "%SCRIPT_DIR%SFSRootCAG2.cer" >nul 2>&1
        echo   Removed downloaded SFSRootCAG2.cer
    )
)
echo.
pause
exit /b
