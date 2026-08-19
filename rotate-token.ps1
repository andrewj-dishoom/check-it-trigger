# Rotate the Check It API token (run monthly, or when the failure alert fires).
# Prefer the web app (checkit-key-manager) if it's deployed — this is the CLI
# fallback. Prompts for the new token securely (no echo, no shell history),
# stores it as a new Secret Manager version, then runs a test fetch.
#
#   .\rotate-token.ps1
#
$ErrorActionPreference = "Stop"
$project = "jp-gs-379412"
$region  = "europe-west2"

$secure = Read-Host "Paste the new Check It API token" -AsSecureString
$bstr   = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
$token  = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

if ([string]::IsNullOrWhiteSpace($token)) { throw "No token entered." }

$tmp = [IO.Path]::GetTempFileName()
try {
    [IO.File]::WriteAllText($tmp, $token)   # WriteAllText => no trailing newline
    gcloud secrets versions add checkit-auth-key --data-file=$tmp --project $project
    if ($LASTEXITCODE -ne 0) { throw "Secret version add failed." }
} finally {
    Remove-Item $tmp -Force
}

Write-Host "`nNew token stored. Running a test fetch (LOOKBACK_DAYS=2, ~1 min)..." -ForegroundColor Cyan
gcloud run jobs execute check-it-fetch --region $region --project $project --wait
if ($LASTEXITCODE -eq 0) {
    Write-Host "`nRotation OK - the token works and a fresh file has landed." -ForegroundColor Green
} else {
    Write-Host "`nTest fetch FAILED - check the logs; the new token may be wrong." -ForegroundColor Red
    Write-Host 'gcloud logging read "resource.type=cloud_run_job AND resource.labels.job_name=check-it-fetch" --limit=20 --freshness=10m --format="value(textPayload)"'
}
