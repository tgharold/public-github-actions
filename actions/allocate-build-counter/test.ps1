#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

$config = New-PesterConfiguration
$config.Run.Path = "$PSScriptRoot/tests"
$config.Output.Verbosity = 'Detailed'
$config.Run.Exit = $true

Invoke-Pester -Configuration $config
