# PowerShell 7 profile installed by deskside (power and developer profiles).
# Plain and safe: nicer history and completion, a clear prompt if Starship is installed. Edit freely.

if (Get-Module -ListAvailable -Name PSReadLine) {
    Import-Module PSReadLine
    Set-PSReadLineOption -PredictionSource History -HistoryNoDuplicates -BellStyle None
    Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
    Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
    Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
}

if (Get-Module -ListAvailable -Name Terminal-Icons) { Import-Module Terminal-Icons }

if (Get-Command starship -ErrorAction SilentlyContinue) {
    # Starship's documented PowerShell setup (starship.rs/guide). It runs only in the person's own PowerShell 7 sessions.
    Invoke-Expression (& starship init powershell)
}

# Quick ways to open common places.
function docs { Set-Location ([Environment]::GetFolderPath('MyDocuments')) }
function dl { Set-Location (Join-Path $HOME 'Downloads') }
