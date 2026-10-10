#Requires -Version 7.6.5

<#
.SYNOPSIS
  Single-repo SSH mirror: git clone --bare src, then git push to N dst urls.
  No API calls, no platform detection. Host/owner/repo all come from the URLs.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SrcUrl,
    [Parameter(Mandatory)][string]$DstUrl,
    [string]$SrcSshKey = '',
    [string]$DstSshKey = '',
    [string]$Branches = '',
    [string]$Tags = 'true',
    [string]$Force = 'true'
)

$ErrorActionPreference = 'Stop'

function Test-True([string]$v) { $v.Trim().ToLowerInvariant() -in @('1', 'true', 'yes', 'y', 'on') }

function ConvertTo-List([string]$raw) {
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    $items = $raw -split "[`r`n,;]+" |
    ForEach-Object { $_.Trim() } |
    ForEach-Object {
        if ($_ -match '^\-\s*(.+)$') { $Matches[1].Trim() } else { $_ }
    } |
    Where-Object { $_ -ne '' }
    # de-dupe, keep order
    $seen = @{}
    $out = @()
    foreach ($i in $items) { if (-not $seen.ContainsKey($i)) { $seen[$i] = $true; $out += $i } }
    return $out
}

function Split-KeyList([string]$raw) {
    # A private key is multi-line, so a naive split would shred it. When the input
    # contains PEM/OpenSSH markers, split on the BEGIN..END blocks instead of on
    # newlines, so a list of real keys survives intact.
    # NOTE: callers must always wrap the result in @(...) so a single key stays an array.
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    if ($raw -match '-----BEGIN') {
        $blocks = [regex]::Matches($raw, '(?s)-----BEGIN[^-]*-----.*?-----END[^-]*-----')
        if ($blocks.Count -gt 0) { return @($blocks | ForEach-Object { $_.Value.Trim() }) }
        return @($raw.Trim())
    }
    return @(ConvertTo-List $raw)
}

function Write-KeyFile([string]$content, [string]$dir, [string]$label) {
    $path = Join-Path $dir ('git-mirror-{0}-{1}' -f $label, [System.IO.Path]::GetRandomFileName())
    (($content.Trim() -replace "`r", '') + "`n") | Set-Content -NoNewline -Encoding ascii -Path $path

    # Sanity check: catch "key got mangled" problems here instead of as an opaque ssh error.
    $written = Get-Content -Raw -Path $path
    if ($written -notmatch '^-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----') {
        Remove-Item -Force -ErrorAction SilentlyContinue $path
        throw "SSH key for '$label' does not look like a private key (got $($written.Trim().Length) chars, expected a '-----BEGIN ... PRIVATE KEY-----' block)."
    }

    # ssh refuses keys with loose permissions, so a failure here is fatal.
    if ($IsWindows) {
        & icacls $path /inheritance:r /grant:r "$($env:USERDOMAIN)\$($env:USERNAME):(F)" 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "icacls failed on key file: $path" }
    }
    else {
        & chmod 600 $path 2>$null
        if ($LASTEXITCODE -ne 0) { throw "chmod 600 failed on key file: $path" }
    }
    return $path
}

function ConvertTo-SshPath([string]$p) { return ($p -replace '\\', '/') }

function Get-SshCommand([string]$keyFile, [string]$knownHosts) {
    # LogLevel=INFO surfaces ssh's own diagnostics (Permission denied (publickey),
    # host key mismatch, etc.). With ERROR, git only reports the generic
    # "Could not read from remote repository" and the real cause is lost.
    $kf = ConvertTo-SshPath $keyFile
    $kh = ConvertTo-SshPath $knownHosts
    # -F ignores ~/.ssh/config so a self-hosted runner's ProxyCommand/Host aliases
    # cannot change behavior (NUL is the Windows equivalent of /dev/null).
    # ServerAlive* detects a stalled transfer; ConnectTimeout only covers dialing.
    $nullCfg = if ($IsWindows) { 'NUL' } else { '/dev/null' }
    $baseOpts = 'StrictHostKeyChecking=accept-new', "UserKnownHostsFile=`"$kh`"",
    'IdentitiesOnly=yes', 'LogLevel=INFO', 'ConnectTimeout=30', 'ServerAliveInterval=30', 'ServerAliveCountMax=4', 'BatchMode=yes' -join ' -o '
    return "ssh -F `"$nullCfg`" -i `"$kf`" -o $baseOpts"
}

function Get-RemoteDefaultBranch([string]$workDir, [string]$SshCommand) {
    # Ask the remote for its current HEAD. The local bare repo's HEAD is only set
    # at clone time and goes stale if the source changes its default branch.
    $prev = $env:GIT_SSH_COMMAND
    $env:GIT_SSH_COMMAND = $SshCommand
    try {
        $out = & git --git-dir=$workDir ls-remote --symref origin HEAD 2>$null
        if ($LASTEXITCODE -eq 0) {
            foreach ($line in @($out)) {
                if ("$line" -match '^ref:\s+refs/heads/(\S+)\s+HEAD') { return $Matches[1] }
            }
        }
    }
    finally { $env:GIT_SSH_COMMAND = $prev }
    return $null
}

function Resolve-LocalDefaultBranch([string]$workDir) {
    # Fallback: clone --bare points HEAD at the source's default branch.
    $head = (& git --git-dir=$workDir symbolic-ref --short HEAD 2>$null)
    if ($LASTEXITCODE -eq 0 -and $head) { return "$head".Trim() }
    return $null
}

# Errors that retrying cannot fix. Matched case-insensitively against combined
# stdout+stderr, so keep entries specific: anything matched here fails fast
# instead of burning ~30s on 5 doomed retries.
$script:FatalGitPattern = 'Permission denied|Permission to .* denied|invalid format|Load key|Host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED|Authentication failed|Repository not found|non-fast-forward|fetch first|\[remote rejected\]|hook declined|protected branch|couldn.t find remote ref|GH001|already exists'

function Invoke-Git([string[]]$GitArgs, [string]$SshCommand, [int]$MaxAttempts = 5) {
    $prev = $env:GIT_SSH_COMMAND
    $env:GIT_SSH_COMMAND = $SshCommand
    try {
        for ($i = 1; $i -le $MaxAttempts; $i++) {
            Write-Host "+ git $($GitArgs -join ' ')"
            $out = & git @GitArgs 2>&1 | ForEach-Object { "$_" }
            $code = $LASTEXITCODE
            $out | ForEach-Object { Write-Host $_ }
            if ($code -eq 0) { return }

            if (($out -join "`n") -match $script:FatalGitPattern) {
                throw "git $($GitArgs[0]) failed with exit $code (non-retryable error, see output above)"
            }
            if ($i -lt $MaxAttempts) {
                # Retry transient failures: destination platforms throttle bursts of new
                # SSH connections and reset them mid-transfer, which a retry usually fixes.
                # Jitter keeps simultaneously throttled jobs from retrying in lockstep.
                $delay = [Math]::Min(30, [Math]::Pow(2, $i)) + (Get-Random -Maximum 3)
                Write-Warning "git failed (exit $code), retry $($i + 1)/$MaxAttempts in ${delay}s"
                Start-Sleep -Seconds $delay
            }
            else { throw "git $($GitArgs[0]) failed with exit $code after $MaxAttempts attempts" }
        }
    }
    finally { $env:GIT_SSH_COMMAND = $prev }
}

# ---------- resolve inputs ----------
$SrcUrl = ($SrcUrl ?? '').Trim()
$dstList = @(ConvertTo-List $DstUrl)
if ([string]::IsNullOrWhiteSpace($SrcUrl)) { throw 'src_url is required.' }
if ($dstList.Count -eq 0) { throw 'dst_url is required (at least one URL).' }

# SSH-only by design. This also blocks option injection (a URL starting with '-'
# would otherwise be parsed as a git flag) and keeps tokens out of the log:
# Invoke-Git echoes the full command line, so an https://token@host/... URL
# would land in plaintext in the workflow log.
$sshUrl = '^(ssh://[^\s/]+/\S+|[\w.-]+@[\w.-]+:\S+)$'
foreach ($u in @($SrcUrl) + $dstList) {
    if ($u -notmatch $sshUrl) { throw "Only SSH URLs are accepted: $u" }
}

# Mirroring a repo onto itself with --prune would delete its own refs.
# Compare case-insensitively: same repo, same disaster, whatever the casing.
foreach ($d in $dstList) {
    if ($d -eq $SrcUrl) { throw "src_url and dst_url must differ (both are '$SrcUrl')." }
}

# dst_ssh_key may be a single key shared by every destination, or a list
# paired positionally with dst_url.
[string[]]$dstKeys = @(Split-KeyList $DstSshKey)
if ($dstKeys.Count -gt 1 -and $dstKeys.Count -ne $dstList.Count) {
    throw "dst_ssh_key has $($dstKeys.Count) keys but dst_url has $($dstList.Count) entries. Provide one key for all, or exactly one per destination."
}

# A single destination key doubles as the source key when no source key was given
$singleDstKey = if ($dstKeys.Count -eq 1) { [string]$dstKeys[0] } else { '' }
$effSrcKey = if (-not [string]::IsNullOrWhiteSpace($SrcSshKey)) { $SrcSshKey } else { $singleDstKey }

# ...and a lone source key covers every destination too.
if ($dstKeys.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($SrcSshKey)) {
    [string[]]$dstKeys = @([string]$SrcSshKey)
}
if ([string]::IsNullOrWhiteSpace($effSrcKey) -or $dstKeys.Count -eq 0) {
    throw 'No SSH key provided. Set src_ssh_key and/or dst_ssh_key. Filling one reuses it for both sides.'
}

$wantTags = Test-True $Tags
$wantForce = Test-True $Force
$branchList = @(ConvertTo-List $Branches)
# "*" -> mirror every branch; empty -> resolve the source's default branch after
# cloning; otherwise treat the list as explicit branch names.
# "*" is the sentinel because git itself rejects it as a ref name, so it can never
# collide with a real branch -- unlike words like "all", which are legal branch names.
$fullMirror = ($branchList.Count -eq 1 -and $branchList[0] -eq '*')
$autoBranch = $branchList.Count -eq 0

# ---------- keys & paths ----------
$base = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
$keyDir = Join-Path $base 'git-mirror-keys'
if (-not (Test-Path $keyDir)) { New-Item -ItemType Directory -Path $keyDir | Out-Null }
$knownHostsFile = Join-Path $keyDir ('known_hosts-' + [System.IO.Path]::GetRandomFileName())
$srcKeyFile = $null
$dstKeyFiles = @()

try {
    # Key creation lives inside try so a mid-way failure still gets cleaned up.
    New-Item -ItemType File -Path $knownHostsFile | Out-Null
    $srcKeyFile = Write-KeyFile $effSrcKey $keyDir 'src'
    $srcSsh = Get-SshCommand $srcKeyFile $knownHostsFile

    # Materialize one key file per destination so each push can use its own key
    for ($i = 0; $i -lt $dstList.Count; $i++) {
        $k = if ($dstKeys.Count -eq 1) { [string]$dstKeys[0] } else { [string]$dstKeys[$i] }
        $dstKeyFiles += (Write-KeyFile $k $keyDir "dst$i")
    }

    # ---------- local bare mirror ----------
    # --bare, not --mirror: --mirror sets remote.origin.fetch=refs/*:refs/* and would
    # pull in refs/pull/*, refs/merge-requests/* and other non-branch refs.
    $safe = ($SrcUrl -replace '[^A-Za-z0-9._-]+', '_').Trim('_')
    $hash = [BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::HashData(
            [System.Text.Encoding]::UTF8.GetBytes($SrcUrl))).Replace('-', '').Substring(0, 8).ToLowerInvariant()
    if ($safe.Length -gt 60) { $safe = $safe.Substring(0, 60) }
    $workDir = Join-Path $base ('git-mirror/' + $safe + '-' + $hash + '.git')

    if (-not (Test-Path (Join-Path $workDir 'HEAD'))) {
        if (Test-Path $workDir) {
            Write-Warning "Cache damaged (no HEAD), re-clone: $workDir"
            Remove-Item -Recurse -Force $workDir
        }
        Write-Host "Clone --bare $SrcUrl -> $workDir"
        Invoke-Git @('clone', '--bare', '--', $SrcUrl, $workDir) $srcSsh
    }

    # Make sure origin points at the requested source URL
    $cur = (& git --git-dir=$workDir remote get-url origin 2>$null)
    if ($cur -ne $SrcUrl) { & git --git-dir=$workDir remote set-url origin $SrcUrl }

    # Resolve the default branch from the remote (fall back to the local HEAD)
    if ($autoBranch) {
        $def = Get-RemoteDefaultBranch $workDir $srcSsh
        if ([string]::IsNullOrWhiteSpace($def)) { $def = Resolve-LocalDefaultBranch $workDir }
        if ([string]::IsNullOrWhiteSpace($def)) {
            throw "Could not determine the default branch of $SrcUrl (source may be empty)."
        }
        $branchList = @($def)
        Write-Host "Default branch: $def"
    }

    Write-Host "Fetch origin in $workDir"
    # --prune-tags (not --prune --tags) is what makes tag deletions propagate.
    # --prune alone never touches refs/tags/*, so a tag removed upstream would stay
    # in the local cache and --tags would re-push it to every destination forever.
    $tagFetchArgs = @("--git-dir=$workDir", 'fetch', '--prune', '--prune-tags', '--tags', 'origin')
    if ($fullMirror) {
        # clone --bare does not write remote.origin.fetch, so an explicit refspec is
        # required or incremental fetches pick up nothing
        Invoke-Git @("--git-dir=$workDir", 'fetch', '--prune', 'origin', '+refs/heads/*:refs/heads/*') $srcSsh
        if ($wantTags) { Invoke-Git $tagFetchArgs $srcSsh }
    }
    else {
        foreach ($b in $branchList) {
            Invoke-Git @("--git-dir=$workDir", 'fetch', '--prune', 'origin', "+refs/heads/${b}:refs/heads/${b}") $srcSsh
        }
        if ($wantTags) { Invoke-Git $tagFetchArgs $srcSsh }
    }

    # ---------- push ----------
    # Guard: never push --prune with zero local branches. An empty source (or a
    # failed fetch that somehow slipped through) would otherwise wipe every branch
    # and tag on all destinations.
    $localHeads = @(git --git-dir=$workDir for-each-ref --format='%(refname:short)' refs/heads/ 2>$null)
    if ($fullMirror -and $localHeads.Count -eq 0) {
        throw "Refusing to push: no local branches found. The source may be empty; pushing with --prune would delete everything on the destinations."
    }

    # LFS objects live outside git data and are never transferred. Warn instead of
    # silently shipping pointer files that resolve to nothing on the destination.
    $checkHeads = if ($fullMirror) { $localHeads } else { $branchList }
    foreach ($b in $checkHeads) {
        $attrs = @(git --git-dir=$workDir show "refs/heads/${b}:.gitattributes" 2>$null)
        if ($LASTEXITCODE -eq 0 -and (($attrs -join "`n") -match 'filter\s*=\s*lfs')) {
            Write-Warning "Branch '$b' uses Git LFS (filter=lfs), but only git data is mirrored: file contents will NOT be transferred."
            break
        }
    }

    $failed = @()
    for ($di = 0; $di -lt $dstList.Count; $di++) {
        $dst = $dstList[$di]
        $dstSsh = Get-SshCommand $dstKeyFiles[$di] $knownHostsFile
        Write-Host "==== push -> $dst ===="
        try {
            if ($fullMirror) {
                # Never --mirror here: it pushes the whole refs/ namespace, so refs/pull/*
                # and friends go to the destination, which rejects hidden refs.
                $pushArgs = @("--git-dir=$workDir", 'push')
                if ($wantForce) { $pushArgs += '--force' }
                if ($wantTags) { $pushArgs += '--tags' }
                # '--' keeps a dst URL starting with '-' from being parsed as a flag.
                # Options (--force/--tags/--prune) must precede it; everything after
                # is repository + refspecs.
                $pushArgs += @('--prune', '--', $dst, 'refs/heads/*:refs/heads/*')
                Invoke-Git $pushArgs $dstSsh
            }
            else {
                # One push for all branches plus tags, so a destination needs a single
                # SSH connection instead of one per branch.
                $pushArgs = @("--git-dir=$workDir", 'push')
                if ($wantForce) { $pushArgs += '--force' }
                if ($wantTags) { $pushArgs += '--tags' }
                # --prune is refspec-scoped: it only deletes destination refs matched by the
                # refspecs below, so branches outside $branchList are never touched. Combined
                # with --tags it is what lets a deleted tag disappear from the destination.
                # '--' keeps a dst URL starting with '-' from being parsed as a flag.
                $pushArgs += @('--prune', '--', $dst)
                # No leading '+' on the refspec: a forced refspec overrides --force, which
                # would make the force input ineffective in this mode.
                foreach ($b in $branchList) { $pushArgs += "refs/heads/${b}:refs/heads/${b}" }
                Invoke-Git $pushArgs $dstSsh
            }
            Write-Host "OK: $dst"
        }
        catch {
            Write-Warning "FAILED: $dst : $_"
            $failed += $dst
        }
    }

    Write-Host ('Src: {0} | Dst total: {1}, ok: {2}, failed: {3}' -f $SrcUrl, $dstList.Count, ($dstList.Count - $failed.Count), $failed.Count)
    if ($failed.Count -gt 0) { throw ('Push failed for: ' + ($failed -join ', ')) }
}
finally {
    $toRemove = @($srcKeyFile) + @($dstKeyFiles) + @($knownHostsFile) | Where-Object { $_ }
    Remove-Item -Force -ErrorAction SilentlyContinue $toRemove
    # Remove the key directory if nothing else is using it
    if ((Test-Path $keyDir) -and -not (Get-ChildItem -Force -Path $keyDir -ErrorAction SilentlyContinue)) {
        Remove-Item -Force -ErrorAction SilentlyContinue $keyDir
    }
}
