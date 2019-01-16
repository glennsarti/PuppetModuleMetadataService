param(
  $S3Bucket = 'puppet-module-metadata-sourcefiles'
)

$ErrorActionPreference = 'Stop'

$zipfile = 'functions.zip'

if (Test-Path $zipfile) { Remove-Item -Path $zipfile -Force -Confirm:$false | Out-Null }

Push-Location functions

Write-Host "Creating zip archive...." -ForegroundColor Green
& 7za a "..\$zipfile" *.rb -ir!vendor '-xr!.bundle'

Pop-Location

Write-Host "Pushing to AWS..." -ForegroundColor Green
& aws s3 cp $zipfile "s3://$S3Bucket/$zipfile"

Write-Host "Updating functions..." -ForegroundColor Green
$result = (& aws lambda list-functions) -join "`n"
$functions = ConvertFrom-JSON $result

$functions.Functions | % {
  $func = $_
  if ($func.FunctionName -like 'pup-module-metadata*') {
    Write-Host "Updating $($func.FunctionName)..." -ForegroundColor Green
    & aws lambda update-function-code --function-name $($func.FunctionName) --s3-bucket $S3Bucket --s3-key functions.zip
  }
}
