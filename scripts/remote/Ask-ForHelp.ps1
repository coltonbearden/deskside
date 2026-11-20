#Requires -Version 5.1
<#
.SYNOPSIS
    The "Ask <helper> for help" button: asks what's wrong (optional) and sends the helper a help request through
    MeshCentral Assistant.

.DESCRIPTION
    Runs as the person at the PC, from the shortcut Install-HelpButton.ps1 puts on the desktop and in the Start menu.
    Checks the agent is connected to the server first, so it never says "sent" when it couldn't be. Only one
    Assistant runs per PC and a second copy drops its request, so this person's running copy is closed and started
    again with -help:"<text>". Line breaks are taken out (a request holding one never arrives).

.PARAMETER HelperName
    The name on the button.

.PARAMETER Text
    The request text, without asking (the Sandbox proof uses it).

.PARAMETER LogFolder
    Starts Assistant with -debug, its debug.log in this folder (the Sandbox proof uses it).

.PARAMETER Quiet
    No message boxes (the Sandbox proof).
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleTypes', '', Justification = 'System.Windows.Forms is loaded by Add-Type before any use.')]
[CmdletBinding()]
param(
    [string]$HelperName = 'your helper',
    [string]$Text,
    [string]$LogFolder,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$title = "Ask $HelperName for help"
$exe = Join-Path $env:ProgramFiles 'deskside\Help\MeshCentralAssistant.exe'

function Show-Box([string]$Message, [string]$Icon) {
    if ($Quiet) { Write-Output $Message; return }
    [void][Windows.Forms.MessageBox]::Show($Message, $title, 'OK', $Icon)
}

function Test-AgentConnected {
    $svc = Get-Service -Name 'Mesh Agent' -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -ne 'Running') { return $false }
    $agentPid = (Get-CimInstance Win32_Service -Filter "Name='Mesh Agent'" -ErrorAction SilentlyContinue).ProcessId
    if (-not $agentPid) { return $false }
    $c = @(Get-NetTCPConnection -OwningProcess $agentPid -State Established -ErrorAction SilentlyContinue | Where-Object { $_.RemoteAddress -ne '127.0.0.1' -and $_.RemoteAddress -ne '::1' })
    return ($c.Count -gt 0)
}

if (-not (Test-Path -LiteralPath $exe)) { Show-Box "The help button isn't set up on this PC any more. Please phone or text $HelperName." 'Warning'; exit 1 }
if (-not (Test-AgentConnected)) { Show-Box "This PC can't reach $HelperName right now (it may be offline). Please phone or text $HelperName instead." 'Warning'; exit 1 }

if (-not $PSBoundParameters.ContainsKey('Text')) {
    $form = New-Object Windows.Forms.Form
    $form.Text = $title; $form.Width = 460; $form.Height = 220; $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'; $form.MaximizeBox = $false; $form.MinimizeBox = $false; $form.TopMost = $true
    $label = New-Object Windows.Forms.Label
    $label.Text = "What do you need help with? You can leave this empty.`n$HelperName will get your request and contact you."
    $label.SetBounds(12, 10, 420, 40)
    $box = New-Object Windows.Forms.TextBox
    $box.SetBounds(12, 56, 420, 24); $box.MaxLength = 200
    $ok = New-Object Windows.Forms.Button
    $ok.Text = 'Send request'; $ok.SetBounds(232, 120, 100, 30); $ok.DialogResult = 'OK'
    $cancel = New-Object Windows.Forms.Button
    $cancel.Text = 'Cancel'; $cancel.SetBounds(338, 120, 94, 30); $cancel.DialogResult = 'Cancel'
    $form.Controls.AddRange(@($label, $box, $ok, $cancel)); $form.AcceptButton = $ok; $form.CancelButton = $cancel
    if ($form.ShowDialog() -ne 'OK') { exit 0 }
    $Text = $box.Text
}

# One line, no quotes or backslashes, 200 characters at most.
$clean = (($Text -replace '[\r\n\t]+', ' ') -replace '["\\]', '' -replace '[\x00-\x1F]', '').Trim()
if ($clean.Length -gt 200) { $clean = $clean.Substring(0, 200) }
if (-not $clean) { $clean = 'Please contact me when you can.' }

# Close this person's own copy (only one runs per PC, and a second one drops its request), then start it again.
$me = [Diagnostics.Process]::GetCurrentProcess().SessionId
Get-Process -Name 'MeshCentralAssistant' -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $me } | ForEach-Object { $_.Kill(); $_.WaitForExit(5000) | Out-Null }
$argList = @('-noupdate', "`"-help:$clean`"")
$dir = Split-Path $exe -Parent
if ($LogFolder) { $argList += '-debug'; $dir = $LogFolder }
Start-Process -FilePath $exe -ArgumentList $argList -WorkingDirectory $dir | Out-Null
Show-Box "Your request is on its way to $HelperName, who will contact you." 'Information'
