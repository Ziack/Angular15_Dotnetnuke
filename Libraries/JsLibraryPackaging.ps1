Set-StrictMode -Version:Latest
#Import-Module PSCX -RequiredVersion 3.2.0.0
Add-Type -AssemblyName 'System.IO.Compression.FileSystem'

function New-Package(
    $directory = '.', 
    $outputPath = '_InstallPackages',
    [switch]$recurse = $false)
{
    if ($directory -is [string]) {
        $directory = Resolve-Path $directory
    } elseif ($directory -is [System.IO.DirectoryInfo]){
        $directory = Resolve-Path $directory.FullName
    }
    #Write-Host ('directory is ' + $directory.Path)

    if ($outputPath -is [string]) {
        $outputPath = Resolve-Path $outputPath
    } elseif ($outputPath -is [System.IO.DirectoryInfo]) {
        $outputPath = Resolve-Path $outputPath.FullName        
    }
    #Write-Host ('output path is ' + $outputPath.Path)

    $zipThisDirectory = -not $recurse
    if ($recurse) {
        $subDirectories = ls $directory -Directory | ? { $_.FullName -ne $outputPath.Path -and $_.Name -notmatch '^_' }
        if (@($subDirectories).Length -gt 0) {
            foreach ($subDirectory in $subDirectories) {
                New-Package -directory $subDirectory -outputPath $outputPath
            }
        } else {
            $zipThisDirectory = $true
        }
    }

    if ($zipThisDirectory) {
        #Write-Host ('zipping ' + $directory.Path)
        try {
			$directory.Path
			$zipName = (Split-Path $directory.Path -Leaf) + '.zip'
	        [System.IO.Compression.ZipFile]::CreateFromDirectory($directory, (Join-Path $outputPath $zipName), [System.IO.Compression.CompressionLevel]::Optimal, $false)
		} catch {
			Write-Error $_.Exception.Message
			""
		}
		
    }
}

function New-BowerLibrary ($name) {
    bower install $name
    if ($name -match '#') {
        $split = $name.Split('#')
        $name = $split[0]
        $version = $split[1]
    }

    $folderName = (bower info $name name --json) | ConvertFrom-Json
    $packageInfo = (Get-Content .\_bower_components\$folderName\.bower.json) -join "`n" | ConvertFrom-Json
    if (@(Get-Member -InputObject $packageInfo | ? { $_.Name -eq 'version' }).Count -gt 0) {
        $version = $packageInfo.version
    }

    $allPaths = (bower list --paths --json) -join "`n" | ConvertFrom-Json
    $paths = @($allPaths.$folderName)
    $jsPaths = @($paths | ? { $_ -match '\.js$' })

    if ($jsPaths.Count -eq 0) {
        $jsPaths = @(ls $paths *.js -Recurse)
    }
    if ($jsPaths.Count -gt 1) {
        Write-Warning 'Package contains multiple JS files, only the first will be listed in the package'
    } 

    $jsFile = $jsPaths[0]
    $fileName = Split-Path $jsFile -Leaf

    $versionedFolder = New-JavaScriptLibrary $name $version $fileName

    $filePaths = @($paths | ? { -not (Test-Path $_ -PathType Container) })
    if ($filePaths.Count -eq 0) {
        $jsPaths | % { cp $_.FullName $versionedFolder }
    } else {
        $filePaths | % { cp $_ $versionedFolder }
    }

    if (@(Get-Member -InputObject $packageInfo | ? { $_.Name -eq 'dependencies' }).Count -gt 0) {
        Write-Warning 'Package has dependencies'; Write-Warning $packageInfo.dependencies
    }
}

function New-JavaScriptLibrary ($name, $version, $jsFileName, $friendlyName) {
    if (-not $friendlyName) {
        $friendlyName = Read-Host "What is the library's friendly name? (blank for '$name')"
        if (-not $friendlyName) {
            $friendlyName = $name
        }
    }

    $versionedFolder = "$($name)_$version"
    mkdir $versionedFolder | Out-Null
  
    $manifestFile = "$versionedFolder\$name.dnn"
    cp _template\library.dnn $manifestFile
    $changesFile = "$versionedFolder\CHANGES.htm"
    cp _template\CHANGES.htm $changesFile
    $licenseFile = "$versionedFolder\LICENSE.htm"
    cp _template\LICENSE.htm $licenseFile

    ReplaceTokens $manifestFile $name $friendlyName $version $jsFileName
    ReplaceTokens $changesFile $name $friendlyName $version $jsFileName
    ReplaceTokens $licenseFile $name $friendlyName $version $jsFileName

    notepad $manifestFile
    notepad $changesFile
    notepad $licenseFile

    return $versionedFolder
}

function Update-BowerLibrary ($name) {
    bower install $name

    $folderName = (bower info $name name --json) | ConvertFrom-Json
    $packageInfo = (Get-Content .\_bower_components\$folderName\.bower.json) -join "`n" | ConvertFrom-Json
    if (@(Get-Member -InputObject $packageInfo | ? { $_.Name -eq 'version' }).Count -gt 0) {
        $newVersion = $packageInfo.version
    }

    $allPaths = (bower list --paths --json) -join "`n" | ConvertFrom-Json
    $paths = @($allPaths.$folderName)
    $jsPaths = @($paths | ? { $_ -match '\.js$' })

    if ($jsPaths.Count -eq 0) {
        $jsPaths = @(ls $paths *.js -Recurse)
    }
    if ($jsPaths.Count -gt 1) {
        Write-Warning 'Package contains multiple JS files, only the first will be listed in the package'
    } 

    $jsFile = $jsPaths[0]
    $jsFolder = [System.IO.Path]::GetDirectoryName($jsFile)
    $jsFileName = [System.IO.Path]::GetFileNameWithoutExtension($jsFile)
    $minJsFile = [System.IO.Path]::Combine($jsFolder, $jsFileName + '.min.js')
    if (Test-Path $minJsFile) {
        $jsFile = $minJsFile
    }

    $oldVersionFolder = Get-Item "$($name)_*"
    cp $jsFile $oldVersionFolder.Name

    Update-JavaScriptLibrary $name $newVersion
}

function Update-JavaScriptLibrary ($name, $newVersion) {
    $oldVersionFolder = Get-Item "$($name)_*"
    $oldVersion = $oldVersionFolder.Name.Substring($name.Length + 1)
    $newVersionFolder = "$($name)_$newVersion"
    mv $oldVersionFolder.Name $newVersionFolder

    $licenseFile = Get-Item "$newVersionFolder\LICENSE.htm"
    (Get-Content $licenseFile) | % { $_ -replace $oldVersion.Replace('.', '\.'), $newVersion } | Set-Content $licenseFile

    $dnnFile = Get-Item "$newVersionFolder\*.dnn"
    (Get-Content $dnnFile) | % { $_ -replace $oldVersion.Replace('.', '\.'), $newVersion } | Set-Content $dnnFile

    $oldParsedVersion = [System.Version]::Parse($oldVersion)
    $newParsedVersion = [System.Version]::Parse($newVersion)
    $oldParsedFolder = "$($oldParsedVersion.Major.ToString('0#'))_$($oldParsedVersion.Minor.ToString('0#'))_$($oldParsedVersion.Build.ToString('0#'))"
    $newParsedFolder = "$($newParsedVersion.Major.ToString('0#'))_$($newParsedVersion.Minor.ToString('0#'))_$($newParsedVersion.Build.ToString('0#'))"
    (Get-Content $dnnFile) | % { $_ -replace $oldParsedFolder, $newParsedFolder } | Set-Content $dnnFile

    git add -A
    git --no-pager diff --cached --find-renames=10%
    git commit -m "$name $newVersion"
}

function ReplaceTokens($file, $name, $friendlyName, $version, $fileName) {
     (Get-Content $file) | 
        % { $_ -replace '\[name\]', $name -replace '\[friendlyName\]', $friendlyName -replace '\[version\]', $version -replace '\[file\]', $fileName } | 
        Set-Content $file
 }

<#
Export-ModuleMember New-JavaScriptLibrary
Export-ModuleMember New-BowerLibrary
Export-ModuleMember Update-JavaScriptLibrary
Export-ModuleMember Update-BowerLibrary
Export-ModuleMember New-Package
#>