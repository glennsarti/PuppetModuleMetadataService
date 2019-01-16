$ErrorActionPreference = 'Stop'

$BundlePath = Join-Path (Join-Path (Join-Path $PSScriptRoot 'functions') 'vendor') 'bundle'
$GemfileLock = Join-Path (Join-Path $PSScriptRoot 'functions') 'Gemfile.lock'

If (Test-Path -Path $BundlePath) { Remove-Item -Path $BundlePath -Recurse -Force -Confirm:$False | Out-Null }
If (Test-Path -Path $GemfileLock) { Remove-Item -Path $GemfileLock -Force -Confirm:$False | Out-Null }
& docker run --rm --volume "$(Join-Path $PSScriptRoot 'functions'):/var/task" stympy/lambda-ruby2.5
If (Test-Path -Path $GemfileLock) { Remove-Item -Path $GemfileLock -Force -Confirm:$False | Out-Null }
