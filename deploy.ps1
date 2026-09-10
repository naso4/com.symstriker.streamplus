<#
.SYNOPSIS
    Uploads this site's current working tree to wotstream.symstriker.com via FTP.

    Mirrors the same content site.zip already bundles (see the wotstream skill's
    `release WSP` command) -- all HTML/CSS/JS pages plus the downloads/ directory
    (installer .exe files, gitignored -- they only exist locally, never in git).
    Deploys whatever is on disk right now, not just what's committed, so it
    picks up the same files site.zip would.

.PARAMETER FtpHost
    FTP server hostname.

.PARAMETER FtpUser
    FTP username.

.PARAMETER FtpPassword
    FTP password.

.PARAMETER RemotePath
    Remote directory that is the site's document root (e.g.
    /home3/symstrik/wotstream.symstriker.com).

.PARAMETER WhatIf
    List the files that would be uploaded without actually uploading anything.

.EXAMPLE
    .\deploy.ps1 -FtpHost wotstream.symstriker.com -FtpUser 'symstriker@wotstream.symstriker.com' -FtpPassword '...' -RemotePath /home3/symstrik/wotstream.symstriker.com
#>
param(
    [Parameter(Mandatory)] [string]$FtpHost,
    [Parameter(Mandatory)] [string]$FtpUser,
    [Parameter(Mandatory)] [string]$FtpPassword,
    [Parameter(Mandatory)] [string]$RemotePath,
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

$siteRoot = $PSScriptRoot

# Files/dirs at the site root that are never part of the published site.
$excludeNames = @(
    '.git', '.gitignore', 'site.zip', 'deploy.ps1', 'tasks'
)

$credential = New-Object System.Net.NetworkCredential($FtpUser, $FtpPassword)
$remotePathNormalized = $RemotePath.TrimEnd('/')

function Get-RemoteUri([string]$relativePath) {
    $relativeUrlPath = ($relativePath -replace '\\', '/')
    return "ftp://$FtpHost$remotePathNormalized/$relativeUrlPath"
}

function Ensure-RemoteDirectory([string]$relativeDirPath) {
    if ([string]::IsNullOrEmpty($relativeDirPath)) { return }
    $parts = $relativeDirPath -split '/'
    $built = ""
    foreach ($part in $parts) {
        $built = if ($built) { "$built/$part" } else { $part }
        $uri = Get-RemoteUri $built
        $req = [System.Net.FtpWebRequest]::Create($uri)
        $req.Credentials = $credential
        $req.Method = [System.Net.WebRequestMethods+Ftp]::MakeDirectory
        try {
            $resp = $req.GetResponse()
            $resp.Close()
        } catch [System.Net.WebException] {
            # 550 = already exists; anything else is a real problem.
            $resp = $_.Exception.Response
            if ($resp -and $resp.StatusCode -ne [System.Net.FtpStatusCode]::ActionNotTakenFileUnavailable) {
                throw
            }
        }
    }
}

function Upload-File([string]$localFullPath, [string]$relativePath) {
    $uri = Get-RemoteUri $relativePath
    $req = [System.Net.FtpWebRequest]::Create($uri)
    $req.Credentials = $credential
    $req.Method = [System.Net.WebRequestMethods+Ftp]::UploadFile
    $req.UseBinary = $true
    $bytes = [System.IO.File]::ReadAllBytes($localFullPath)
    $req.ContentLength = $bytes.Length
    $stream = $req.GetRequestStream()
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Close()
    $resp = $req.GetResponse()
    $resp.Close()
}

# -Force is required to include dotfiles like .htaccess (Get-ChildItem hides
# them by default). Excluded top-level entries (e.g. .git) are filtered out
# BEFORE recursing into them, so we never walk .git's huge internal tree.
# (Get-ChildItem on a file path with -Recurse -File just returns that file,
# so this correctly covers both top-level files and files inside subfolders.)
$files = Get-ChildItem $siteRoot -Force | Where-Object {
    -not ($excludeNames -contains $_.Name)
} | Get-ChildItem -Recurse -File -Force -ErrorAction SilentlyContinue

Write-Host "Found $($files.Count) file(s) to deploy to ftp://$FtpHost$remotePathNormalized/`n"

$createdDirs = New-Object System.Collections.Generic.HashSet[string]
$i = 0
foreach ($f in $files) {
    $i++
    $relativePath = $f.FullName.Substring($siteRoot.Length + 1) -replace '\\', '/'
    $relativeDir = Split-Path $relativePath -Parent

    if ($WhatIf) {
        Write-Host "[$i/$($files.Count)] would upload: $relativePath"
        continue
    }

    if ($relativeDir -and -not $createdDirs.Contains($relativeDir)) {
        Ensure-RemoteDirectory ($relativeDir -replace '\\', '/')
        [void]$createdDirs.Add($relativeDir)
    }

    Write-Host "[$i/$($files.Count)] uploading: $relativePath"
    Upload-File $f.FullName $relativePath
}

Write-Host "`nDone." -ForegroundColor Green
