<#
.DESCRIPTION
    Functionality and utilities related to development containers using Docker.
    
    This module expects 'docker', 'docker-compose' and 'devcontainer.cmd' in the PATH environment variable.
    
    A 'vscode' service must exist in the Docker compose file.
#>

# [Initializations] ####################################################################################################

# Stop script on first error found.
$ErrorActionPreference = "Stop";

# Imports.
Import-Module "$PSScriptRoot/commons.psm1";

# [Declarations] #######################################################################################################

# [Internal Functions] #################################################################################################

# [Functions] ##########################################################################################################
function Initialize-DevContainer
{
    <#
    .DESCRIPTION
        Builds the images and containers from the development container configuration files specified.

    .PARAMETER DevcontainerFile
        Path to the 'devcontainer.json' file. This is usually in the '.devcontainer' directory.

    .PARAMETER ProjectName
        The name of the compose project to build or create.

    .PARAMETER Inputs
        Input artifacts that will be copied accross prior to building images, they follow the format:

        @{
            "input_1" = @{
                "srcPath" = "/path/to/source";
                "destPath" = "/path/to/dest/";
            };
        }

        The 'destPath' must be a path in the build context of the services to build.

    .PARAMETER Outputs
        Output artifacts that will be copied to the host from the development containers, they follow the format:

        @{
            "output_1" = @{
                "containerPath" = "/path/to/source";
                "hostPath" = "/path/to/dest/";
            };
        }

        The 'containerPath' is the path in the container.

    .EXAMPLE
        Initialize-DevContainer -DevcontainerFile ".devcontainer/devcontainer.json" -ProjectName "project"
    #>
    param (
        [Parameter(Mandatory = $true)]
        [String]
        $DevcontainerFile,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [String]
        $ProjectName,
        [Parameter(Mandatory = $false)]
        [hashtable]
        $Inputs,
        [Parameter(Mandatory = $false)]
        [hashtable]
        $Outputs
    )

    Write-Log "Building development container images at '$DevcontainerFile'...";

    # Ensure path to configuration files exist.
    if (-not (Test-Path "$DevcontainerFile"))
    {
        throw "'$DevcontainerFile' file does not exist.";
    }

    # Handle input artifacts.
    if ($PSBoundParameters.ContainsKey("Inputs"))
    {
        foreach ($key in $Inputs.Keys)
        {
            Write-Log "Copying input artifact '$key'...";
            New-CopyItem -Source "$($Inputs.$key.srcPath)" -Destination "$($Inputs.$key.destPath)";
        }
    }

    # Create images and run containers, do not use cache for the images and recreate containers if they exist.
    # Note that devcontainer does not modify the last exit code, query the 'vscode' container creation for success.
    Write-Log "Building images and development containers with no cache, running until healthy...";
    $env:COMPOSE_PROJECT_NAME = $ProjectName;
    & "devcontainer" up --config "$DevcontainerFile" --remove-existing-container --build-no-cache --log-level "debug";
    $vscodeContainerID = & "docker-compose" --project-name "$ProjectName" ps --all --quiet "vscode";
    if (-not $vscodeContainerID)
    {
        throw "Failed to build images and development containers.";
    }
    $env:COMPOSE_PROJECT_NAME = $null;

    # Stop required containers after they have been built.
    Write-Log "Stopping development container...";
    & "docker-compose" --project-name "$ProjectName" stop;
    if ($LASTEXITCODE -ne 0)
    {
        throw "Failed to stop development container with error '$LASTEXITCODE'.";
    }

    # Handle output artifacts after stopping the containers.
    if ($PSBoundParameters.ContainsKey("Outputs"))
    {
        foreach ($key in $Outputs.Keys)
        {
            Write-Log "Copying output artifact '$key' from container to host...";
            & "docker" cp "$($vscodeContainerID):$($Outputs.$key.containerPath)" "$($Outputs.$key.hostPath)";
            if ($LASTEXITCODE -ne 0)
            {
                throw "Failed to copy artifact from development container with error '$LASTEXITCODE'.";
            }
        }
    }
    
    # When finished, remove development containers created, and keep the images.
    Write-Log "Removing development containers created and attached volumes...";
    & "docker-compose" --project-name "$ProjectName" down --volumes;
    if ($LASTEXITCODE -ne 0)
    {
        throw "Failed to remove development containers with error '$LASTEXITCODE'.";
    }

    Write-Log "Development container images created successfully." "Success";
}

########################################################################################################################
function Start-DevContainer
{
    <#
    .DESCRIPTION
        Runs a development container in the current working directory, opening Visual Studio Code.
        
        If the development container already exists, it is used, otherwise a new one is created.

        If the volumes associated to the development container exist, they are used, otherwise they are created.

    .PARAMETER DevcontainerFile
        Path to the 'devcontainer.json' file. This is usually in the '.devcontainer' directory.

    .PARAMETER ProjectName
        The name of the compose project to start.

    .PARAMETER VolumeInitScript
        The initialization script for the volume associated to the 'vscode' service with the workspace, this script
        only runs when the volume is empty.
        
        This script can be used for example to clone the target repository.

    .PARAMETER Inputs
        Input artifacts that will be copied accross when development container is created, they follow the format:

        @{
            "input_1" = @{
                "hostPath" = "/path/to/source";
            };
        }

        The artifacts are copied to "/vol_store" folder, from there, they can be interacted with from the
        initialization script.

    .EXAMPLE
        Start-DevContainer -DevcontainerFile ".devcontainer/devcontainer.json" -ProjectName "project"
    #>
    param (
        [Parameter(Mandatory = $true)]
        [String]
        $DevcontainerFile,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [String]
        $ProjectName,
        [Parameter(Mandatory = $false)]
        [String]
        $VolumeInitScript,
        [Parameter(Mandatory = $false)]
        [hashtable]
        $Inputs
    )

    # Ensure path to configuration files exist.
    if (-not (Test-Path "$DevcontainerFile"))
    {
        throw "'$DevcontainerFile' file does not exist.";
    }

    # Use 'docker-compose' rather than the devcontainer CLI to create the development container, as the latter does not
    # work well with images, attempting to rebuild them when there are features. In this case, do not build or pull
    # images, expect them all to exist locally already to avoid side-effects.
    #
    # This implies that if using features, when building the image the resulting Dockerfile with the feature, see the
    # log-level when building for details, need to be inspected for initialization scripts of the feature, and those
    # added might need to be executed manually from the terminal within VSCode.
    Write-Log "Starting development container '$ProjectName'...";
    & "docker-compose" --project-directory "$(Split-Path "$DevcontainerFile" -Parent)" --project-name "$ProjectName" `
        up --detach --no-build --no-recreate --pull "never" --wait;
    $vscodeContainerID = & "docker-compose" --project-name "$ProjectName" ps --all --quiet "vscode";
    $isRunning = & "docker" ps --filter "id=$($vscodeContainerID)" --filter "status=running" --quiet --no-trunc;
    if (-not $isRunning)
    {
        throw "Failed to start development container with error '$error'.";
    }
    
    # Get the workspace folder from the 'devcontainer.json' file.
    $workspaceFolder = (New-JSONC -JSONCPath "$DevcontainerFile").workspaceFolder;
    if ($workspaceFolder.Length -eq 0)
    {
        throw "The field 'workspaceFolder' must be specified in '$DevcontainerFile'.";
    }

    # Determine if the 'vscode' volume, is empty or not before copying the artifacts and running the
    # initialization script, if it is already initialized, then skip this step.
    $isInitialized = (& "docker-compose" --project-name "$ProjectName" exec --workdir "$workspaceFolder" "vscode" `
            pwsh -Command "ls").Length -gt 0;
    if (-not ($isInitialized))
    {
        # Create folder for artifacts to be copied and for internals.
        & "docker-compose" --project-name "$ProjectName" exec --workdir "$workspaceFolder" "vscode" `
            pwsh -Command "New-Item -Force -ItemType 'Directory' -Path '/vol_store' | Out-Null;";
        if ($LASTEXITCODE -ne 0)
        {
            throw "Failed to create 'vol_store' folder with error '$LASTEXITCODE'.";
        }
        
        # Handle input artifacts.
        if ($PSBoundParameters.ContainsKey("Inputs"))
        {
            foreach ($key in $Inputs.Keys)
            {
                # Get name of artifact and copy it to the temporary folder.
                $artifactName = Split-Path -Path "$($Inputs.$key.hostPath)" -Leaf;
                Write-Log "Copying input artifact '$key' from host to container...";
                & "docker" cp "$($Inputs.$key.hostPath)" "$($vscodeContainerID):/vol_store/$artifactName";
                if ($LASTEXITCODE -ne 0)
                {
                    throw "Failed to copy artifact from host to development container with error '$LASTEXITCODE'.";
                }
            }
        }
        
        # Handle initialization script.
        if ($PSBoundParameters.ContainsKey("VolumeInitScript"))
        {
            # Create temporary file where to save the temporary script.
            $tempFile = New-TemporaryFile;
            $fileName = Split-Path -Path "$tempFile" -Leaf;
            try
            {
                # Create file with the contents of the script and copy it into the container.
                Set-Content -Path "$tempFile" -Value $VolumeInitScript;
                & "docker" cp "$tempFile" "$($vscodeContainerID):/vol_store/$fileName";
                if ($LASTEXITCODE -ne 0)
                {
                    throw "Failed to copy initialization script into container with error '$LASTEXITCODE'.";
                }
                
                # Run script.
                Write-Log "Running initialization script for 'vscode' volume...";
                & "docker-compose" --project-name "$ProjectName" exec --workdir "$workspaceFolder" "vscode" `
                    pwsh -File "/vol_store/$filename";
                if ($LASTEXITCODE -ne 0)
                {
                    throw "Initialization script for volume failed with error '$LASTEXITCODE'.";
                }
            }
            finally
            {
                # Delete temporary file with the script in the host.
                Remove-Item -Path $tempFile;
                # Delete temporary file with the script in the container.
                & "docker-compose" --project-name "$ProjectName" exec --workdir "$workspaceFolder" "vscode" `
                    pwsh -c "if (Test-Path '/vol_store/$fileName') { Remove-Item '/vol_store/$fileName' -Force; }";
            }
        }
    }

    # Open development container.
    Write-Log "Opening folder '$PWD' in Visual Studio code and development container...";
    $env:COMPOSE_PROJECT_NAME = $ProjectName;
    & "devcontainer" open "$PWD" --config "$DevcontainerFile" --disable-telemetry;
    $env:COMPOSE_PROJECT_NAME = $null;
}

# [Execution] ##########################################################################################################
Export-ModuleMember Initialize-DevContainer;
Export-ModuleMember Start-DevContainer;
