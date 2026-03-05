---
Module Name: utils
Module Guid: 00000000-0000-0000-0000-000000000000
Download Help Link: {{ Update Download Link }}
Help Version: {{ Please enter version of help manually (X.X.X.X) format }}
Locale: en-US
---

# Add-WAFResourceTopology

## SYNOPSIS

Enriches the collector `ResourceInventory` with network topology fields.

## DESCRIPTION

`Add-WAFResourceTopology` runs additional Azure Resource Graph (ARG) queries to populate `topology_*` properties on resources in `ResourceInventory`.

This enrichment is used by downstream steps such as network topology generation and reporting.

## TOPOLOGY FIELDS (HIGHLIGHTS)

- VNet/subnet relationships derived from NICs and subnets.
- Public endpoints derived from Public IPs.
- Private Endpoint relationships derived from Private Endpoints.
- `topology_publicNetworkAccess` backfill for:
  - App Services (`microsoft.web/sites`)
  - PostgreSQL Flexible Server (`microsoft.dbforpostgresql/flexibleservers`) via `properties.network.publicNetworkAccess` (fallback to `properties.publicNetworkAccess` when present).
  - Azure SQL Server (`microsoft.sql/servers`) via `properties.publicNetworkAccess`.
  - Storage Account (`microsoft.storage/storageaccounts`) via `properties.publicNetworkAccess`.

- App Service SKU backfill:
  - For App Services (`microsoft.web/sites`), if `sku` is empty in the inventory projection, the function attempts to derive it from the associated App Service Plan (`microsoft.web/serverfarms`) using `properties.serverFarmId`.

- VNet integration (delegated subnet) enrichment:
  - PostgreSQL Flexible Server (`microsoft.dbforpostgresql/flexibleservers`) via `properties.network.delegatedSubnetResourceId`.
  - MySQL Flexible Server (`microsoft.dbformysql/flexibleservers`) via `properties.network.delegatedSubnetResourceId`.

- Offline-friendly subnet metadata:
  - `topology_subnetPrefixPairs`: `subnetId|cidr` pairs.
  - `topology_subnetDetails`: `subnetId|subnetName|cidr|delegations` records (VNet resources only).

## PARAMETERS

### -ResourceInventory

The collector resource inventory (objects must include `id` and `type`).

### -SubscriptionIds

The subscription IDs used to scope ARG queries.

## OUTPUTS

Returns the updated inventory objects (same objects, enriched with `topology_*` properties).
