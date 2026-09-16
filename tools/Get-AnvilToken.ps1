<#
.SYNOPSIS
    Obtains an access token from the identity provider using Authorization Code
    with PKCE, for manual testing of a resource server.

.DESCRIPTION
    Starts a local listener on the redirect port, opens the browser at the
    authorization endpoint, captures the code, verifies the state, and exchanges
    the code for tokens. The redirect URI must already be registered for the
    client being used.

    Dot-source this file to make the function available:

        . C:\dev\anvil\tools\Get-AnvilToken.ps1

.EXAMPLE
    $token = Get-AnvilToken

.EXAMPLE
    $token = Get-AnvilToken -ClientId carga-web -Port 5273 -ForceLogin
#>

function Get-AnvilToken {
    [CmdletBinding()]
    param(
        [string]$ClientId = "pistachio-admin",
        [int]$Port = 5173,
        [string]$Authority = "http://anvil.localtest.me:8081/realms/anvil",
        [string]$Scope = "openid profile email",
        [switch]$ForceLogin
    )

    if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
        throw "Port $Port is already in use. Stop whatever is listening on it first."
    }

    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] 32
    $rng.GetBytes($bytes)
    $verifier = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $hash = $sha256.ComputeHash([System.Text.Encoding]::ASCII.GetBytes($verifier))
    $challenge = [Convert]::ToBase64String($hash).TrimEnd('=').Replace('+', '-').Replace('/', '_')

    $state = [Guid]::NewGuid().ToString()
    $nonce = [Guid]::NewGuid().ToString()
    $redirect = "http://localhost:$Port/"

    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add($redirect)
    $listener.Start()

    try {
        $query = @(
            "response_type=code"
            "client_id=$([uri]::EscapeDataString($ClientId))"
            "redirect_uri=$([uri]::EscapeDataString($redirect))"
            "scope=$([uri]::EscapeDataString($Scope))"
            "state=$state"
            "nonce=$nonce"
            "code_challenge=$challenge"
            "code_challenge_method=S256"
        )
        if ($ForceLogin) { $query += "prompt=login" }

        Start-Process "$Authority/protocol/openid-connect/auth?$($query -join '&')"

        Write-Host "Waiting for the browser to come back to $redirect ..."

        $context = $listener.GetContext()
        $code = $context.Request.QueryString["code"]
        $returnedState = $context.Request.QueryString["state"]
        $error = $context.Request.QueryString["error"]

        $message = if ($code) { "Token obtained. Return to PowerShell." } else { "Authorization failed: $error" }
        $out = [System.Text.Encoding]::UTF8.GetBytes($message)
        $context.Response.OutputStream.Write($out, 0, $out.Length)
        $context.Response.Close()
    }
    finally {
        $listener.Stop()
    }

    if ($error) { throw "Authorization endpoint returned: $error" }
    if ($returnedState -ne $state) { throw "State mismatch. Possible cross-site request forgery." }

    $response = curl.exe -s -X POST "$Authority/protocol/openid-connect/token" `
        -d "grant_type=authorization_code" `
        -d "client_id=$ClientId" `
        -d "redirect_uri=$redirect" `
        -d "code=$code" `
        -d "code_verifier=$verifier" | ConvertFrom-Json

    if (-not $response.access_token) {
        throw ($response | ConvertTo-Json -Depth 5)
    }

    $response.access_token
}

function Show-Jwt {
    [CmdletBinding()]
    param([Parameter(Mandatory, ValueFromPipeline)][string]$Token)

    process {
        $payload = $Token.Split('.')[1].Replace('-', '+').Replace('_', '/')
        switch ($payload.Length % 4) { 2 { $payload += '==' } 3 { $payload += '=' } }
        [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
    }
}
