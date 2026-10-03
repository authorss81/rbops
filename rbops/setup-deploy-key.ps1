# One-shot setup: give the rbops pipeline push access to authorss81/redblue
# WITHOUT a hand-made PAT, using an SSH deploy key (least privilege).
#
# What it does:
#   1. generates an ed25519 keypair in a temp dir (no passphrase)
#   2. registers the public half as a WRITE deploy key on authorss81/redblue
#      (rotates any previous key with the same title)
#   3. saves the private half as the REDBLUE_DEPLOY_KEY secret on authorss81/rbops
#   4. proves end-to-end write access with a dry-run push, then wipes the key
#      material from disk
#
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File setup-deploy-key.ps1
# Re-running is safe: it rotates the key.

# PowerShell treats EVERY stderr line from a native tool (git's "Cloning
# into...", ssh banners) as fatal under 'Stop', so: Continue globally, and all
# native calls go through Invoke-Native, which throws on a non-zero exit.
$ErrorActionPreference = 'Continue'

function Invoke-Native {
  param([Parameter(Mandatory)][string]$Exe,
        [Parameter(ValueFromRemainingArguments)][string[]]$Rest)
  # Stringify: native stderr arrives as ErrorRecord objects, which PowerShell
  # re-renders as red failures at every downstream pipe even on exit 0.
  # Silent on success (the caller uses the returned lines); indented dump only
  # on failure. Emitting AND returning duplicates every line, which once parsed
  # a key listing twice and double-deleted a deploy key.
  $out = @(& $Exe @Rest 2>&1 | ForEach-Object { "$_" })
  $code = $LASTEXITCODE
  if ($code -ne 0) {
    $out | ForEach-Object { Write-Output "      | $_" }
    throw "'$Exe' exited $code"
  }
  return $out
}

$Owner  = 'authorss81'
$Target = "$Owner/redblue"   # repo receiving the deploy key (needs push)
$Pipe   = "$Owner/rbops"     # repo holding the secret (pipeline runs here)
$Title  = 'rbops-pipeline'   # deploy-key title; re-runs replace it

foreach ($t in @('gh', 'ssh-keygen', 'git')) {
  if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { throw "required tool not found on PATH: $t" }
}
Invoke-Native gh auth status | Out-Null

$work = Join-Path ([IO.Path]::GetTempPath()) 'rbops-deploy-key'
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Path $work | Out-Null
try {
  $key = Join-Path $work 'id_ed25519'
  Invoke-Native ssh-keygen -t ed25519 -N '""' -C "$Title@$Owner" -f $key -q | Out-Null
  $pub = (Get-Content "$key.pub" -Raw).Trim()

  Write-Output "-- deploy keys currently on $Target"
  # Out-String first: without it the JSON array arrives line-by-line and parses
  # into duplicates, which then double-deletes below.
  $existing = @(((Invoke-Native gh api "repos/$Target/keys") | Out-String) | ConvertFrom-Json)
  foreach ($k in $existing) { Write-Output ("   {0} {1} read_only={2}" -f $k.id, $k.title, $k.read_only) }

  # Rotate: drop any stale key with our title so re-runs stay idempotent.
  foreach ($k in $existing) {
    if ($k.title -eq $Title) {
      Write-Output ("-- removing stale key id={0}" -f $k.id)
      Invoke-Native gh api --method DELETE ("repos/$Target/keys/{0}" -f $k.id) | Out-Null
    }
  }

  Write-Output "-- registering WRITE deploy key '$Title' on $Target"
  $created = ((Invoke-Native gh api "repos/$Target/keys" --method POST `
    -f title="$Title" --raw-field key="$pub" -F read_only=false) | Out-String) | ConvertFrom-Json
  Write-Output ("   id={0} read_only={1}" -f $created.id, $created.read_only)
  if ($created.read_only) { throw 'GitHub created the key read-only; expected write' }

  Write-Output '-- saving private half as secret REDBLUE_DEPLOY_KEY'
  Get-Content $key -Raw | gh secret set REDBLUE_DEPLOY_KEY --repo $Pipe 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'gh secret set failed' }
  $hit = Invoke-Native gh secret list --repo $Pipe | Select-String 'REDBLUE_DEPLOY_KEY'
  Write-Output ("   secret present: {0}" -f $hit.Line.Trim())

  # End-to-end proof: clone over SSH with ONLY this key, then dry-run a push.
  # A dry-run changes nothing but fails exactly like a real push would.
  # StrictHostKeyChecking=accept-new pins github.com into a THROWAWAY known_hosts
  # (no ssh-keyscan needed, no touching the user's real one).
  Write-Output '-- proving write access (clone + push --dry-run, changes nothing)'
  $kh = Join-Path $work 'known_hosts'
  New-Item -ItemType File -Path $kh -Force | Out-Null
  $env:GIT_SSH_COMMAND = "ssh -i `"$key`" -o IdentitiesOnly=yes -o UserKnownHostsFile=`"$kh`" -o StrictHostKeyChecking=accept-new"
  try {
    Invoke-Native git clone --depth 1 "git@github.com:$Target.git" (Join-Path $work 'probe') | Select-Object -Last 1
    Push-Location (Join-Path $work 'probe')
    try {
      Invoke-Native git push --dry-run origin HEAD:main | Select-Object -Last 1
    } finally { Pop-Location }
  } finally { Remove-Item Env:\GIT_SSH_COMMAND -ErrorAction SilentlyContinue }
  Write-Output '   OK: dry-run push accepted — the pipeline can now ship phase work'
}
finally {
  Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
  Write-Output '-- key material wiped from disk'
}
Write-Output 'DONE: REDBLUE_DEPLOY_KEY is set.'