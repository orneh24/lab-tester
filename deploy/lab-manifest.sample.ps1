# lab-manifest.sample.ps1 — placeholder deploy manifest for deploy-routers.ps1.
#
# Copy this file to lab-manifest.ps1 (gitignored) and fill in real values.
# Nothing here is a real address — same convention as docs/csr-baseline.cfg
# and docs/csr-example-r1.cfg, which this manifest's fields feed once you
# apply config by hand per docs/DEPLOYMENT.md stage 1.
#
# Two variables: $Lab (everything that does not vary per router) and
# $Routers (one hashtable per router). deploy-routers.ps1 dot-sources this
# file, so both must stay top-level variables, not a function or module.

$Lab = @{
    # Client-side path or URL to the CSR1000v .ova — NOT a vSphere datastore
    # path. Get-OvfConfiguration reads this from the machine running
    # PowerCLI, not from vCenter.
    OvaPath = "C:\iso\csr1000v-universalk9.ova"

    # Empty -> deploy-routers.ps1 falls back to (Get-VMHost | Select-Object -First 1)
    VMHost    = ""
    Datastore = "<datastore-name>"

    # Run deploy-routers.ps1 -ShowOvfOptions against your actual OvaPath to
    # find the exact DeploymentOption string your OVA release uses — these
    # vary across CSR1000v releases and this project has no OVA to check
    # against. The smallest option is what this project needs: nothing in
    # csr-baseline.cfg/csr-example-r1.cfg needs more than 1 vCPU / 4 GB RAM
    # (Cisco's documented minimum for IOS XE 16.x+ on ESXi) and the "ipbase"
    # boot level (BGP, VRF-Lite, NAT, SNMP, LLDP, SSH are all in IP Base —
    # nothing here needs security/appx/ax). For 3 routers that is 12 GB RAM
    # total, dwarfing the hub (192 MB) and every test VM (128 MB) — size
    # the ESXi host accordingly. Throughput tier and license entitlement
    # are yours to confirm; this script does not assume either.
    DeploymentOption = "<deployment-option-from--ShowOvfOptions>"
    DiskFormat       = "Thin"

    # Port groups shared by every router. Must already exist in vCenter —
    # this script fails fast naming any that are missing, it never creates
    # one (VLAN ID / vSwitch ownership belongs to whoever provisions
    # infrastructure, not to a per-deploy manifest).
    MgmtPG    = "VLAN199-Management"
    OutsidePG = "VLAN100-Outside-shared"

    # vNIC-ordinal convention this project uses everywhere csr-example-r1.cfg
    # says <MGMT_IF>/<OUTSIDE_IF>/<INSIDE_IF> — see that file's placeholder
    # header. GigabitEthernet1 is the CSR OVA's own default management
    # interface, and it is the interface docs/DEPLOYMENT.md says needs
    # `vrf forwarding MGMT` applied before anything else depends on it.
    MgmtIf    = "GigabitEthernet1"
    OutsideIf = "GigabitEthernet2"
    InsideIf  = "GigabitEthernet3"

    # --- Not used by deploy-routers.ps1 (Phase 1) --------------------------
    # Shaped in now so this file only needs writing once, when a config
    # renderer or hub-registration script is built later. Safe to leave as
    # placeholders until then.
    OutsideMask   = "255.255.255.0"
    MgmtMask      = "255.255.255.0"
    InternetGW    = "<internet-gateway-on-outside-shared>"
    HubUrl        = "http://<hub-nic1-ip>"
    HubMgmtIP     = "<hub-nic2-ip>"
    UpstreamNtpIP = "<real-upstream-ntp-server>"
    DnsServer     = "<dns-server-ip>"
    DomainName    = "<domain-name>"
}

# One row per router. InsideCidr is deliberately one field, not separate
# subnet/mask/wildcard entries -- those three can disagree with each other,
# and a mismatched `network <subnet> mask <mask>` in BGP fails silently (the
# prefix just never appears). It is also the exact string guestinfo.lab.subnet
# needs, so the router and its test VM cannot disagree about the subnet.
#
# Name is the join key for everything this router touches: the vCenter VM
# name (lab-<name>), IOS `hostname`, the name syslog puts in its own
# messages, guestinfo.lab.router on its test VM, and snmp_targets.name on
# the hub. Keep it short and match the router's real IOS hostname exactly.
$Routers = @(
    @{
        Name       = "R1"
        AS         = 65001
        LoopbackIP = "10.255.255.1"
        MgmtIP     = "10.99.0.11"
        OutsideIP  = "10.0.0.11"
        InsideGW   = "10.1.1.1"
        InsideCidr = "10.1.1.0/24"
        InsidePG   = "VLAN101-R1-inside"
    }
    @{
        Name       = "R2"
        AS         = 65002
        LoopbackIP = "10.255.255.2"
        MgmtIP     = "10.99.0.12"
        OutsideIP  = "10.0.0.12"
        InsideGW   = "10.2.2.1"
        InsideCidr = "10.2.2.0/24"
        InsidePG   = "VLAN102-R2-inside"
    }
    @{
        Name       = "R3"
        AS         = 65003
        LoopbackIP = "10.255.255.3"
        MgmtIP     = "10.99.0.13"
        OutsideIP  = "10.0.0.13"
        InsideGW   = "10.3.3.1"
        InsideCidr = "10.3.3.0/24"
        InsidePG   = "VLAN103-R3-inside"
    }
)
