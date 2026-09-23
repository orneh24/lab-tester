#requires -Modules VMware.VimAutomation.Core
<#
.SYNOPSIS
    Deploys a mesh-probe hub and N nodes from existing vCenter templates.

.DESCRIPTION
    Clones one hub VM and (by default) three node VMs from the two golden
    templates this project builds (see hub/build-template.sh and
    node/build-template.sh), sets the guestinfo keys each role's firstboot
    service reads (see CLAUDE.md, "Per-VM configuration: guestinfo"), and
    powers them on. This script only does vSphere-side provisioning — every
    in-guest step (static IP, registration, test-cycle) is the zero-touch
    firstboot path already built into the templates; this script's whole job
    is to hand it the guestinfo it's waiting for before first boot.

    Requires an existing PowerCLI session (Connect-VIServer) — this script
    does not prompt for or handle vCenter credentials itself.

.PARAMETER HubTemplate
    Name of the hub golden template in vCenter (built by hub/build-template.sh).

.PARAMETER NodeTemplate
    Name of the node golden template in vCenter (built by node/build-template.sh).
    The project ships two separate templates for the two roles — this is not
    a typo, see CLAUDE.md's Infrastructure section.

.PARAMETER PortGroup
    Network (standard or distributed portgroup) to attach the hub and every
    node to. One flat network for the whole deployment; see the notes below
    if your topology needs nodes on different segments.

.PARAMETER VMHost
    ESXi host to place every cloned VM on.

.PARAMETER Datastore
    Datastore to place every cloned VM on.

.PARAMETER Folder
    vCenter VM folder to place the clones in. Defaults to the datacenter's
    root VM folder if omitted.

.PARAMETER HubIP
    Hub's static IP in CIDR form, e.g. "10.0.0.100/24". Written to
    guestinfo.hub.ip, read by the hub's firstboot service
    (mesh-probe-hub-firstboot). Required — the hub needs a predictable
    address for nodes to register against and for an operator to reach.

.PARAMETER HubGateway
    Hub's default gateway. Written to guestinfo.hub.gateway.

.PARAMETER HubVMName
    vCenter display name for the hub clone. Default: mesh-probe-hub.

.PARAMETER NodeCount
    Number of nodes to deploy. Default: 3.

.PARAMETER NodeNamePrefix
    Prefix for each node's vCenter VM name (<prefix>-<group>). guestinfo.meshprobe.
    hostname is deliberately never set by this script — CLAUDE.md documents
    the same derivation for a node's in-guest hostname when it's left unset,
    so the vCenter VM name and the eventual in-guest hostname naturally end
    up identical, which -WaitForRegistration depends on to match nodes by
    name. Keep this equal to HOSTNAME_PREFIX in the node template's config
    (default in node/config.sample: test-node) or that matching breaks.

.PARAMETER NodeGroups
    One group label per node (guestinfo.meshprobe.group) — an arbitrary tag that
    clusters nodes on the dashboard and filters syslog by sender; it carries
    no network-topology meaning to the hub. Must supply at least $NodeCount
    entries. Default: site-a, site-b, site-c.

.PARAMETER NodeSubnets
    Optional, one entry per node (CIDR, e.g. "10.1.1.0/24"), written to
    guestinfo.meshprobe.subnet. Leave unset (the default) to let each node derive
    its subnet from its own DHCP lease at first boot — the normal path;
    only override where that derivation would be wrong.

.PARAMETER DnsServer
    Optional. Applied to every node as guestinfo.meshprobe.dns_server. Omit to
    leave the DNS test disabled on every node (the documented default —
    "unset skips the DNS test").

.PARAMETER DnsQuery
    Name to resolve when DnsServer is set. Default: example.com.

.PARAMETER PowerOn
    Power on each clone once its guestinfo is set. Default: on. Pass
    -PowerOn:$false to stage the VMs without booting them (e.g. to hand-check
    guestinfo in the vSphere UI first).

.PARAMETER WaitForRegistration
    After powering on, poll the hub's /endpoints for up to 10 minutes and
    report which nodes have registered. Best-effort and non-fatal — a node
    that hasn't shown up by the timeout is reported, not treated as a script
    failure, since first boot + DHCP + a 5-minute registration cycle can
    legitimately take a while.

.EXAMPLE
    Connect-VIServer vcenter.lab.local
    ./Deploy-MeshProbe.ps1 -HubTemplate mesh-probe-hub-template `
        -NodeTemplate mesh-probe-node-template -PortGroup "VM Network" `
        -VMHost esxi01.lab.local -Datastore datastore1 `
        -HubIP 10.0.0.100/24 -HubGateway 10.0.0.1

    Deploys the hub and 3 nodes (site-a/site-b/site-c) on one flat network.

.EXAMPLE
    ./Deploy-MeshProbe.ps1 -HubTemplate hub-tmpl -NodeTemplate node-tmpl `
        -PortGroup "VM Network" -VMHost esxi01 -Datastore ds1 `
        -HubIP 10.0.0.100/24 -HubGateway 10.0.0.1 -WhatIf

    Preview only — lists what would be created without touching vCenter.

.NOTES
    Nodes on genuinely different network segments (the usual real topology —
    "one node per network segment under test", CLAUDE.md) need different
    portgroups per node. This script deploys onto one shared PortGroup for
    simplicity; for a multi-segment lab, run it once per segment with
    -NodeCount matched to that segment, or extend $PortGroup to an array
    indexed the same way -NodeGroups already is.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $HubTemplate,
    [Parameter(Mandatory)] [string] $NodeTemplate,
    [Parameter(Mandatory)] [string] $PortGroup,

    [Parameter(Mandatory)] [string] $VMHost,
    [Parameter(Mandatory)] [string] $Datastore,
    [string] $Folder,

    [Parameter(Mandatory)]
    [ValidatePattern('^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}$')]
    [string] $HubIP,
    [Parameter(Mandatory)] [string] $HubGateway,
    [string] $HubVMName = "mesh-probe-hub",

    [ValidateRange(1, 64)] [int] $NodeCount = 3,
    [string] $NodeNamePrefix = "test-node",
    [string[]] $NodeGroups = @("site-a", "site-b", "site-c"),
    [string[]] $NodeSubnets,
    [string] $DnsServer,
    [string] $DnsQuery = "example.com",

    [switch] $PowerOn = $true,
    [switch] $WaitForRegistration
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------
if (-not $global:DefaultVIServers -or $global:DefaultVIServers.Count -eq 0) {
    throw "Not connected to vCenter. Run Connect-VIServer first."
}
if ($NodeGroups.Count -lt $NodeCount) {
    throw "NodeGroups has $($NodeGroups.Count) entries but NodeCount is $NodeCount — " +
          "supply at least one group label per node."
}
if ($NodeSubnets -and $NodeSubnets.Count -lt $NodeCount) {
    throw "NodeSubnets was supplied but only has $($NodeSubnets.Count) entries for " +
          "$NodeCount nodes. Omit it entirely to let every node derive its subnet " +
          "from DHCP instead of partially overriding it."
}

# guestinfo.hub.ip carries the CIDR (matches CLAUDE.md's own example,
# "10.0.0.100/24"); the URL nodes register against needs the bare address.
$hubAddress = $HubIP.Split('/')[0]
$hubUrl = "http://$hubAddress"

function Set-Guestinfo {
    param([Parameter(Mandatory)] $VM, [Parameter(Mandatory)] [string] $Key, [Parameter(Mandatory)] [string] $Value)
    # Advanced settings must land before first boot — firstboot.initd (hub)
    # and node/services/firstboot.initd (node) both read guestinfo once, at
    # boot, with no re-check later. Caller is responsible for ordering this
    # before Start-VM.
    New-AdvancedSetting -Entity $VM -Name $Key -Value $Value -Confirm:$false | Out-Null
}

function New-CloneParams {
    param([Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] [string] $Template)
    $p = @{
        Name        = $Name
        Template    = $Template
        VMHost      = $VMHost
        Datastore   = $Datastore
        NetworkName = $PortGroup
        Confirm     = $false
    }
    if ($Folder) { $p["Location"] = $Folder }
    return $p
}

# ---------------------------------------------------------------------
# Hub
# ---------------------------------------------------------------------
Write-Host "Cloning hub '$HubVMName' from template '$HubTemplate'..."
$hubVM = $null
if ($PSCmdlet.ShouldProcess($HubVMName, "Clone from $HubTemplate")) {
    $hubCloneParams = New-CloneParams -Name $HubVMName -Template $HubTemplate
    $hubVM = New-VM @hubCloneParams

    Set-Guestinfo -VM $hubVM -Key "guestinfo.hub.ip" -Value $HubIP
    Set-Guestinfo -VM $hubVM -Key "guestinfo.hub.gateway" -Value $HubGateway

    if ($PowerOn) {
        Write-Host "Powering on $HubVMName..."
        Start-VM -VM $hubVM -Confirm:$false | Out-Null
    }
}

# ---------------------------------------------------------------------
# Nodes
# ---------------------------------------------------------------------
$nodeVMs = @()
for ($i = 0; $i -lt $NodeCount; $i++) {
    $group = $NodeGroups[$i]
    $nodeName = "$NodeNamePrefix-$group"

    Write-Host "Cloning node '$nodeName' (group '$group') from template '$NodeTemplate'..."
    if (-not $PSCmdlet.ShouldProcess($nodeName, "Clone from $NodeTemplate")) { continue }

    $nodeCloneParams = New-CloneParams -Name $nodeName -Template $NodeTemplate
    $nodeVM = New-VM @nodeCloneParams

    Set-Guestinfo -VM $nodeVM -Key "guestinfo.meshprobe.hub_url" -Value $hubUrl
    Set-Guestinfo -VM $nodeVM -Key "guestinfo.meshprobe.group" -Value $group
    if ($NodeSubnets) {
        Set-Guestinfo -VM $nodeVM -Key "guestinfo.meshprobe.subnet" -Value $NodeSubnets[$i]
    }
    if ($DnsServer) {
        Set-Guestinfo -VM $nodeVM -Key "guestinfo.meshprobe.dns_server" -Value $DnsServer
        Set-Guestinfo -VM $nodeVM -Key "guestinfo.meshprobe.dns_query" -Value $DnsQuery
    }

    if ($PowerOn) {
        Write-Host "Powering on $nodeName..."
        Start-VM -VM $nodeVM -Confirm:$false | Out-Null
    }
    $nodeVMs += [pscustomobject]@{ Name = $nodeName; Group = $group; VM = $nodeVM }
}

# ---------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------
Write-Host ""
Write-Host "Deployed:"
if ($hubVM) { Write-Host "  Hub:   $HubVMName  ($HubIP via $HubGateway)  ->  $hubUrl" }
foreach ($n in $nodeVMs) { Write-Host "  Node:  $($n.Name)  (group $($n.Group))" }

# ---------------------------------------------------------------------
# Optional: wait for nodes to register
# ---------------------------------------------------------------------
if ($WaitForRegistration -and $PowerOn -and $nodeVMs.Count -gt 0) {
    Write-Host ""
    Write-Host "Waiting for nodes to register with $hubUrl (up to 10 minutes)..."
    Write-Host "This is best-effort: DHCP, first boot, and the 5-minute registration" `
               "cycle can legitimately take a while, so a timeout here is reported," `
               "not treated as a deployment failure."

    $deadline = (Get-Date).AddMinutes(10)
    $pending = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($n in $nodeVMs) { [void]$pending.Add($n.Name) }

    while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
        try {
            $endpoints = Invoke-RestMethod -Uri "$hubUrl/endpoints" -TimeoutSec 10
            foreach ($ep in $endpoints) {
                if ($pending.Contains($ep.hostname)) {
                    Write-Host "  registered: $($ep.hostname) ($($ep.ip))"
                    [void]$pending.Remove($ep.hostname)
                }
            }
        } catch {
            Write-Verbose "Hub not reachable yet at $hubUrl ($($_.Exception.Message))"
        }
        if ($pending.Count -gt 0) { Start-Sleep -Seconds 15 }
    }

    if ($pending.Count -gt 0) {
        Write-Warning "Still not registered after 10 minutes: $($pending -join ', ')"
        Write-Warning "Not necessarily a problem — check console/DHCP on those VMs directly."
    } else {
        Write-Host "All nodes registered."
    }
}
