$ErrorActionPreference = 'Stop'

$versionLine = Select-String -Path 'pubspec.yaml' -Pattern '^version:\s*' |
    Select-Object -First 1

if ($null -eq $versionLine) {
    throw 'pubspec.yaml version line was not found.'
}

$version = ($versionLine.Line -replace '^version:\s*', '').Trim()

if ($version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+\+[0-9]+$') {
    throw "pubspec.yaml version must use x.y.z+build, got: $version"
}

$buildNumber = [int]($version -replace '^.*\+', '')
if ($buildNumber -le 0) {
    throw 'Flutter build number must be greater than zero.'
}

if ($env:GITHUB_REF_TYPE -eq 'tag') {
    $expectedTag = "v$version"
    if ($env:GITHUB_REF_NAME -ne $expectedTag) {
        throw "Release tag must match pubspec.yaml version. Expected $expectedTag, got $env:GITHUB_REF_NAME"
    }
}

Write-Host "Flutter version ok: $version"
