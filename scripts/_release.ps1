# Shared by Build-WaxRelease.ps1 and Publish-Release.ps1 (after _common.ps1): the key a release is signed with, and the check of its signed list.

# The public key as the installer holds it: 128 hex digits, X then Y. It is the same key in every part of Wax.
function Get-ReleaseKey {
    $text = Get-Content -LiteralPath (Join-Path $Root 'wax\release\payload\Wax-Setup.ps1') -Raw
    $found = [regex]::Matches($text, "(?m)^\`$SigningKey = '([0-9a-f]{128})'\r?$")
    if ($found.Count -ne 1) { throw "wax\release\payload\Wax-Setup.ps1 should hold one line `$SigningKey = '<128 hex digits>'." }
    $key = $found[0].Groups[1].Value
    $catalogue = Join-Path $Root 'wax\market\lib\signing.mjs'
    if (Test-Path -LiteralPath $catalogue) {
        $theirs = [regex]::Match((Get-Content -LiteralPath $catalogue -Raw), "PUBLIC_KEY = '([0-9a-f]{128})'").Groups[1].Value
        if ($theirs -ne $key) { throw 'The installer and the catalogue tool hold different public keys. There is one signing key.' }
    }
    $key
}

# What people compare the key by: the SHA-256 of its 64 bytes.
function Get-KeyFingerprint([string]$KeyHex) {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Convert]::FromHexString($KeyHex))).ToLower()
}

# True when the bytes carry this signature of the key: ECDSA on P-256 with SHA-256, the signature as r then s in base64.
function Test-ReleaseSignature([byte[]]$Bytes, [string]$Signature, [string]$KeyHex) {
    if ($Signature -cnotmatch '^[A-Za-z0-9+/]{85}[AQgw]==$' -or $KeyHex -cnotmatch '^[0-9a-f]{128}$') { return $false }
    $key = [Convert]::FromHexString($KeyHex)
    $point = [Security.Cryptography.ECPoint]::new()
    $point.X = [byte[]]$key[0..31]
    $point.Y = [byte[]]$key[32..63]
    $parameters = [Security.Cryptography.ECParameters]::new()
    $parameters.Curve = [Security.Cryptography.ECCurve+NamedCurves]::nistP256
    $parameters.Q = $point
    try {
        $ecdsa = [Security.Cryptography.ECDsa]::Create($parameters)
        try { return $ecdsa.VerifyData($Bytes, [Convert]::FromBase64String($Signature), [Security.Cryptography.HashAlgorithmName]::SHA256) }
        finally { $ecdsa.Dispose() }
    } catch {
        return $false
    }
}

# Stops unless the list is signed with the key, is for this version, and names exactly these files as they are on disk.
function Assert-ReleaseSigned {
    param([string]$Version, [string[]]$Files, [string]$Manifest, [string]$Signature, [string]$KeyHex)
    foreach ($file in @($Manifest, $Signature) + $Files) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "$file not found. Build-WaxRelease.ps1 writes the signed list of a release on the owner's PC." }
    }
    $bytes = [IO.File]::ReadAllBytes($Manifest)
    $signed = [IO.File]::ReadAllText($Signature)
    if (-not $signed.EndsWith("`n") -or -not (Test-ReleaseSignature $bytes $signed.Trim() $KeyHex)) {
        throw "$Manifest does not carry the signature of the key in Wax-Setup.ps1, so no player's updater would accept it."
    }
    $lines = [Text.Encoding]::ASCII.GetString($bytes).Split([char]10)
    if ($lines.Count -lt 2 -or $lines[-1] -ne '' -or $lines[0] -cne "release $Version") { throw "$Manifest is not the list of files of Wax $Version." }
    $listed = [Collections.Hashtable]::new([StringComparer]::Ordinal)
    for ($i = 1; $i -lt $lines.Count - 1; $i++) {
        if ($lines[$i] -cnotmatch '^([0-9a-f]{64}) (\d{1,12}) ([A-Za-z0-9._-]{1,100})$') { throw "$Manifest holds a line that is not a checksum, a size and a file name." }
        $listed[$Matches[3]] = "$($Matches[1]) $($Matches[2])"
    }
    foreach ($file in $Files) {
        $name = Split-Path $file -Leaf
        $actual = "$((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLower()) $((Get-Item -LiteralPath $file).Length)"
        if (-not $listed.ContainsKey($name)) { throw "$name is not in the signed list. Run Build-WaxRelease.ps1 again once every file of the release is built." }
        if ($listed[$name] -cne $actual) { throw "$name changed after the list was signed. Run Build-WaxRelease.ps1 again." }
        $listed.Remove($name)
    }
    if ($listed.Count) { throw "The signed list names files that are not part of this release: $($listed.Keys -join ', '). Run Build-WaxRelease.ps1 again." }
}
