<#
.SYNOPSIS
    Deploy N CSR1000v router VMs from a lab-manifest.ps1, with correct
    per-router network mapping. Phase 1 only: this script deploys bare VMs.
    Config application (csr-baseline.cfg, then the per-router config) stays
    a manual console step per docs/DEPLOYMENT.md stage 1 -- see "No day-0
    config injection" below for why.

.DESCRIPTION
    Extends the PowerCLI bulk-deploy pattern already documented in
    docs/BUILD_GUIDE.md (hashtable-array manifest, -Confirm:$false on every
    mutating cmdlet, (Get-VMHost | Select-Object -First 1) as the host
    fallback) from that pattern's test-VM clone-from-template shape to an
    OVA import with three vNICs per router.

    vNIC convention (write-once, referenced everywhere csr-example-r1.cfg
    says <MGMT_IF>/<OUTSIDE_IF>/<INSIDE_IF>): GigabitEthernet1 = mgmt,
    GigabitEthernet2 = outside, GigabitEthernet3 = inside. This matches the
    CSR OVA's own default management interface (Gi1) and puts the
    VRF-bearing interface first, since docs/DEPLOYMENT.md requires
    `vrf forwarding MGMT` to land on it before anything else depends on it.

    Networks are mapped at OVA IMPORT TIME via the OVF configuration object,
    never with a post-import Get-NetworkAdapter | Set-NetworkAdapter --
    that cmdlet pair pipes every adapter on the VM into one call, which with
    three NICs would silently put mgmt/outside/inside on the same port
    group: a full-mesh short circuit where the dashboard matrix would read
    green while measuring nothing.

    No day-0 config injection. csr-baseline.cfg applies `vrf forwarding
    MGMT` to the mgmt interface as its very first act, and `vrf forwarding`
    WIPES an interface's existing IP configuration (docs/DEPLOYMENT.md's own
    documented trap). Injecting a management IP via an OVF bootstrap
    property would have csr-baseline.cfg immediately wipe it and cut the
    session that property existed to provide. So every com.cisco.csr1000v.*
    bootstrap property is left unset below -- only NetworkMapping.* and
    DeploymentOption are set. Console access (vCenter web console or VMRC)
    is required for the config step that follows; that's already a stated
    prerequisite for this lab, not a new one.

.NOTES
    A lab vCenter with a self-signed certificate needs this once per
    workstation, or Connect-VIServer fails with an error that never
    mentions certificates:
        Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false

    No update/re-provision mode. For test VMs, Get-AdvancedSetting |
    Set-AdvancedSetting is a real "change an existing key" operation
    (docs/BUILD_GUIDE.md). Nothing this script sets is ever changed
    afterward under the no-day-0-injection design above -- network mappings
    are structural, sizing is a resize, and router config lives on the
    router, updated through the hub's existing publish-config path
    (hub/build-template.sh), not through this script. Re-running this
    script against an already-deployed router is a no-op (see the
    already-exists skip below), not an update path.

.PARAMETER Manifest
    Path to a dot-sourceable manifest defining $Lab and $Routers. See
    lab-manifest.sample.ps1.

.PARAMETER OvaPath
    Overrides $Lab.OvaPath from the manifest.

.PARAMETER DryRun
    Validate the manifest and print the per-router deployment plan, then
    exit. No vCenter connection required. Exercises everything except the
    actual OVA import.

.PARAMETER ShowOvfOptions
    Parse $Lab.OvaPath and print its discovered network-mapping keys and
    valid DeploymentOption values, then exit. Needs the OVA file but not a
    vCenter connection. Run this first against your actual OVA release --
    OVF property names vary across CSR1000v releases and this project has
    no OVA to verify against.

.PARAMETER NoStart
    Import the routers but do not power them on.
#>

param(
    [string]$Manifest = (Join-Path $PSScriptRoot "lab-manifest.ps1"),
    [string]$OvaPath,
    [switch]$DryRun,
    [switch]$ShowOvfOptions,
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'

# --- Load the manifest ------------------------------------------------------

if (-not (Test-Path $Manifest)) {
    throw "Manifest not found: $Manifest`nCopy lab-manifest.sample.ps1 to lab-manifest.ps1 and fill in real values."
}
. $Manifest

if ($OvaPath) { $Lab.OvaPath = $OvaPath }

# --- Offline validation (no vCenter contact yet) ----------------------------
#
# Same precedent as this project's shell helpers: check what has actually
# caused a silent failure before, name what's wrong, stop. No retry, no
# partial-apply -- a broken manifest should never deploy half a lab.

$requiredLabKeys = @(
    "OvaPath", "Datastore", "DeploymentOption", "DiskFormat",
    "MgmtPG", "OutsidePG", "MgmtIf", "OutsideIf", "InsideIf"
)
$missingLabKeys = $requiredLabKeys | Where-Object { -not $Lab.ContainsKey($_) -or [string]::IsNullOrWhiteSpace($Lab[$_]) }
if ($missingLabKeys) {
    throw "`$Lab is missing or has empty values for: $($missingLabKeys -join ', ')"
}

$requiredRouterKeys = @(
    "Name", "AS", "LoopbackIP", "MgmtIP", "OutsideIP",
    "InsideGW", "InsideCidr", "InsidePG"
)
foreach ($r in $Routers) {
    $missing = $requiredRouterKeys | Where-Object { -not $r.ContainsKey($_) -or [string]::IsNullOrWhiteSpace([string]$r[$_]) }
    if ($missing) {
        throw "Router '$($r.Name)' is missing or has empty values for: $($missing -join ', ')"
    }
}

# Duplicate identity fields silently break eBGP (duplicate AS, duplicate
# outside IP) or collapse the router->everything-else join key (duplicate
# Name -- the same failure mode CLAUDE.md constraint 1 describes for test
# VM hostnames, one tier up). Check every row against every other row
# before deploying any of them.
foreach ($field in @("Name", "AS", "LoopbackIP", "OutsideIP", "MgmtIP", "InsidePG")) {
    $dupes = $Routers | Group-Object { $_[$field] } | Where-Object { $_.Count -gt 1 }
    if ($dupes) {
        $values = ($dupes | ForEach-Object { $_.Name }) -join ', '
        throw "Duplicate $field across routers: $values"
    }
}

if (-not (Test-Path $Lab.OvaPath)) {
    throw "OvaPath not readable: $($Lab.OvaPath)`nThis must be a client-side path or URL, not a vSphere datastore path -- Get-OvfConfiguration reads it from this machine, not from vCenter."
}

# --- Build the deployment plan (used by -DryRun and the real run alike) ----

$plan = foreach ($r in $Routers) {
    [pscustomobject]@{
        Name      = $r.Name
        VMName    = "lab-" + $r.Name.ToLower()
        Gi1_Mgmt  = $Lab.MgmtPG
        Gi2_Out   = $Lab.OutsidePG
        Gi3_In    = $r.InsidePG
        Datastore = $Lab.Datastore
        Deploy    = $Lab.DeploymentOption
    }
}

if ($DryRun) {
    Write-Host "Deployment plan ($($Routers.Count) router(s)):"
    $plan | Format-Table -AutoSize
    Write-Host "`n-DryRun: no vCenter connection made, nothing deployed."
    return
}

# --- OVF discovery -----------------------------------------------------------

if ($ShowOvfOptions) {
    $cfg = Get-OvfConfiguration -Ovf $Lab.OvaPath
    Write-Host "OVF configuration keys for $($Lab.OvaPath):"
    $cfg.ToHashTable() | Format-Table -AutoSize
    Write-Host "`nValid DeploymentOption values:"
    $cfg.DeploymentOption.Values
    return
}

# --- vCenter connection ------------------------------------------------------

if (-not $global:DefaultVIServer) {
    throw "Not connected to vCenter. Run: Connect-VIServer <vcenter-fqdn-or-ip>"
}

$vmhost = if ($Lab.VMHost) { Get-VMHost $Lab.VMHost } else { Get-VMHost | Select-Object -First 1 }
$datastore = Get-Datastore -Name $Lab.Datastore

# --- Port-group pre-flight ---------------------------------------------------
#
# Missing or wrong port-group assignment is this script's worst possible
# failure: the router boots, comes up, and the dashboard matrix reads green
# while measuring nothing, because mgmt/outside/inside all landed on one
# segment. Check every port group this deploy needs exists BEFORE importing
# anything, and report every missing one in one pass -- one trip to vCenter
# to fix three typos beats three round trips.

function Test-LabPortGroup {
    param([string]$Name)
    if (Get-VirtualPortGroup -Name $Name -ErrorAction SilentlyContinue) { return $true }
    if (Get-VDPortgroup -Name $Name -ErrorAction SilentlyContinue) { return $true }
    return $false
}

$neededPortGroups = @($Lab.MgmtPG, $Lab.OutsidePG) + ($Routers | ForEach-Object { $_.InsidePG }) | Select-Object -Unique
$missingPortGroups = $neededPortGroups | Where-Object { -not (Test-LabPortGroup $_) }
if ($missingPortGroups) {
    throw "Port group(s) not found in vCenter: $($missingPortGroups -join ', ')`nPort groups are stage-0 infrastructure (docs/DEPLOYMENT.md) -- this script does not create them."
}

# --- OVF configuration, read once -------------------------------------------
#
# Get-OvfConfiguration is a slow client-side parse of the .ova. Re-reading
# it per router would be N times the wait for no benefit -- only the
# per-router NetworkMapping value (Gi3) changes across the loop.

$cfg = Get-OvfConfiguration -Ovf $Lab.OvaPath
$cfg.NetworkMapping.($Lab.MgmtIf).Value = $Lab.MgmtPG
$cfg.NetworkMapping.($Lab.OutsideIf).Value = $Lab.OutsidePG
$cfg.DeploymentOption.Value = $Lab.DeploymentOption

# --- Deploy --------------------------------------------------------------

foreach ($r in $Routers) {
    $vmName = "lab-" + $r.Name.ToLower()

    $existing = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "skip: $vmName already exists"
        continue
    }

    # Gi3 (inside) is the one NIC that differs per router -- re-set it each
    # pass on the shared $cfg object before importing.
    $cfg.NetworkMapping.($Lab.InsideIf).Value = $r.InsidePG

    Write-Host "Importing $vmName ..."
    Import-VApp -Source $Lab.OvaPath `
                -Name $vmName `
                -VMHost $vmhost `
                -Datastore $datastore `
                -DiskStorageFormat $Lab.DiskFormat `
                -OvfConfiguration $cfg `
                -Confirm:$false | Out-Null

    Write-Host "  $($r.Name) -> $vmName  $($Lab.MgmtIf)=$($Lab.MgmtPG)  $($Lab.OutsideIf)=$($Lab.OutsidePG)  $($Lab.InsideIf)=$($r.InsidePG)"

    if (-not $NoStart) {
        Start-VM -VM $vmName -Confirm:$false | Out-Null
    }
}

# --- Next steps --------------------------------------------------------------

Write-Host ""
Write-Host "Deployed. Config is not applied -- console in to each router:"
Write-Host "  1. Apply docs/csr-baseline.cfg (identical across every router)."
Write-Host "  2. Apply the per-router config (docs/csr-example-r1.cfg is the worked example)."
Write-Host "  3. Do the mgmt VRF before anything else depends on the mgmt interface --"
Write-Host "     'vrf forwarding' wipes an interface's existing IP config."
Write-Host "  4. Before applying config, run 'show lldp neighbors' on each router --"
Write-Host "     it's the cheapest way to catch a Gi2/Gi3 swap while it's still obvious."
Write-Host "See docs/DEPLOYMENT.md stage 1 for the full sequence."
