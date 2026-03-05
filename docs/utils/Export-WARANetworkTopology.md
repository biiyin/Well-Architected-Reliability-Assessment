# Export-WARANetworkTopology

This document describes the behavior of [tools/Export-WARANetworkTopology.ps1](../../tools/Export-WARANetworkTopology.ps1).

## Purpose

Generate a simplified (deduplicated) network topology diagram (Mermaid) and optional graph JSON from WARA outputs.

## Mermaid diagram rules (high-level)

- Resources are grouped by `(resource type + connected network)` and represented as `grp_*` nodes.
- Virtual Networks are represented as `vnet_*` nodes.
- When a group is publicly exposed (public IP/FQDN, or explicit Public Network Access enabled), it is connected to `Public Internet`.
- VNet peerings are drawn as `---|peering|` edges between VNet nodes.
- To reduce clutter, when there are many peering-only VNets (VNets that have no non-peering connections in the diagram) the script may collapse them into a single aggregated VNet node labeled `Peering VNets (xN)`.

## Mermaid diagram mode

The script can emit either:

- One diagram per Resource Group (default)
- A single high-level diagram for the entire input (`-MergeMermaidDiagrams`)

## VNet peering aggregation

When generating Mermaid output, the script can collapse large groups of *peering-only* VNets:

- A VNet is considered *peering-only* when it has no non-peering connections represented in the diagram (for example workloads connected to the VNet, or Private Endpoint hub edges).
- Peering-only VNets are clustered by their peering neighbor set.
- If a cluster size is greater than or equal to `-PeeringAggregationThreshold` (default: `3`), the cluster is shown as one aggregated VNet node.

This keeps the topology readable in hub-and-spoke environments where many VNets only participate in peering.

## Network Interface (NIC) folding

For Mermaid output, `microsoft.network/networkinterfaces` groups are excluded from the diagram. NICs are an implementation detail for connectivity; the diagram should show the relationship between the workload (for example VMs) and the network (VNet/Public Internet) without inserting extra NIC nodes.

This affects Mermaid output only; the per-type summary sections can still list `microsoft.network/networkinterfaces` inventory details.
