[CmdletBinding()]
param (
    [Parameter()]
    [string] $MetadataPath = "./metadata.ps1",

    [Parameter()]
    [switch] $StrictMode,

    [Parameter()]
    [switch] $WhatIf,

    [Parameter()]
    [string] $CodeOpsModulePath
)

$ErrorActionPreference = $ErrorAction ? $ErrorAction : "Stop"
$InformationPreference = $InformationAction ? $InformationAction : "Continue"

# Setup the required modules
$moduleName = "Endjin.CodeOps"
Get-Module $moduleName | Remove-Module
if (!$CodeOpsModulePath) {
    if ( !(Get-Module -ListAvailable $moduleName) ) {
        Write-Information "Installing module: $moduleName"
        Install-Module $moduleName -Scope CurrentUser -Repository PSGallery -Force
    }
    # Find the latest installed version of the module
    $CodeOpsModulePath = Get-Module -ListAvailable $moduleName | Sort-Object Version -Desc | Select-Object -First 1 | Select-Object -ExpandProperty Path
    if (!$CodeOpsModulePath) {
        throw "The $moduleName module could not be found - check previous log messages"
    }
}
Import-Module $CodeOpsModulePath
Write-Information ("Loaded $moduleName v{0}" -f (Get-Module $moduleName | Select-Object -ExpandProperty Version))


$here = Split-Path -Parent $PSCommandPath


function _generateApiEntity {

}


function _processRepo {

    <#
    - Find the solutions
    - Find OpenAPI yaml definitions
        - create an API for each definition
    - Create a component entity for each solution
        - link APIs
    - Link component to `all-components` index
    #>

    $solutionFiles = Get-ChildItem -Recurse -Filter *.sln

    foreach ($solution in $solutionFiles) {

        Write-Information "Processing solution: $($solution.FullName)"

        $apiDefs = Get-ChildItem -Path (Split-Path -Parent $solution) -Recurse -Filter *.yaml
        foreach ($api in $apiDefs) {
            $apiDef = Get-Content $api | ConvertFrom-Yaml
            if ($apiDef.ContainsKey("openapi")) {
                Write-Information "Processing OpenAPI definitions: $($api.FullName)"
                $githubUri = $api.FullName.Replace($PWD, "").Replace([IO.Path]::DirectorySeparatorChar,"/").TrimStart("/")
                $apiEntityName = "{0}-api" -f $apiDef.info.title.ToLower().Replace(" ", "-")
                Invoke-EpsTemplate `
                    -Path $here/templates/api-entity.tmpl.yaml `
                    -Binding @{
                        ApiName = $apiEntityName
                        ApiDescription = $apiDef.info.title
                        GitHubOwnerRepo = "$($repo.owner.login)/$($repo.name)"
                        SystemName = $org.System
                        OpenApiSpecUri = "https://github.com/$($repo.owner.login)/$($repo.name)/blob/$BranchName/$githubUri"
                    } |
                Out-File $here/../tmp/$($apiEntityName).yaml -Force
            }
        }
    }
}

function _main {

    # Read all existing repo config that might have specific settings configured
    $metadata = . $MetadataPath

    foreach ($org in $metadata) {

        Write-Information "`n`n**********************************"
        Write-Information "** Processing Org: $($org.name) **"
        Write-Information "**********************************`n"
        # Obtain an access token for the current GitHub Org
        # NOTE: This gets stored in $env:GITHUB_TOKEN as per the GitHub Actions convention
        Connect-GitHubOrg -OrgName $org.name -InformationAction $InformationPreference

        # Fail early if we still don't have a GITHUB authentication token
        if (!($env:GITHUB_TOKEN)) {
            Write-Error "A GitHub organisation access token could not be found - if running interactively, try running 'gh auth login'"
        }

        # Find all the repos in the org in preparation for applying the default team access permissions
        $allRepos = Invoke-GitHubRestMethod -Uri "https://api.github.com/orgs/$($org.name)/repos" -AllPages
        $activeRepos = $allRepos | Where-Object { -not $_.archived }

        foreach ($repo in $activeRepos) {

            Write-Information "`n`n** Processing Repo: $($repo.name) **"

            $BranchName = Get-GitHubRepoDefaultBranch -OrgName $repo.owner.login -RepoName $repo.name

            Update-Repo `
                    -OrgName $repo.owner.login `
                    -RepoName $repo.name `
                    -BranchName $BranchName `
                    -RepoChanges (Get-ChildItem function:\_processRepo).ScriptBlock `
                    -RepoChangesArguments @() `
                    -WhatIf:$WhatIf `
                    -CommitMessage "empty commit message that won't be used" `
                    -PrTitle "empty PR title that won't be used" `
                    -PrBody "empty PR body that won't be used" `
                    -PrLabels $null
        }
    }
}

# Detect when dot sourcing the script, so we don't immediately execute anything when running Pester
if (!$MyInvocation.Line.StartsWith('. ')) {

    if ($WhatIf) {
        Write-Host "*** Running in DryRun Mode ***"
    }
    $statusCode = _main
    exit $statusCode
}
