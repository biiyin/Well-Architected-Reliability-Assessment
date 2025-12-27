# Export-WARANetworkTopology

This document describes the behavior of [tools/Export-WARANetworkTopology.ps1](../../tools/Export-WARANetworkTopology.ps1).

## Purpose

Generate a simplified (deduplicated) network topology diagram (Mermaid) and optional graph JSON from WARA outputs.

## Mermaid diagram rules (high-level)

- Resources are grouped by `(resource type + connected network)` and represented as `grp_*` nodes.
- Virtual Networks are represented as `vnet_*` nodes.
- When a group is publicly exposed (public IP/FQDN, or explicit Public Network Access enabled), it is connected to `Public Internet`.

## Network Interface (NIC) folding

For Mermaid output, `microsoft.network/networkinterfaces` groups are excluded from the diagram. NICs are an implementation detail for connectivity; the diagram should show the relationship between the workload (for example VMs) and the network (VNet/Public Internet) without inserting extra NIC nodes.

This affects Mermaid output only; the per-type summary sections can still list `microsoft.network/networkinterfaces` inventory details.
