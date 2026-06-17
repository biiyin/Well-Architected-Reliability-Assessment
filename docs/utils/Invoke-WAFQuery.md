---
external help file: utils-help.xml
Module Name: utils
online version:
schema: 2.0.0
---

# Invoke-WAFQuery

## SYNOPSIS

{{ Fill in the Synopsis }}

## SYNTAX

```text
Invoke-WAFQuery [[-subscriptionIds] <String[]>] [[-query] <String>] [-ProgressAction <ActionPreference>]
 [<CommonParameters>]
```

## DESCRIPTION

Runs an Azure Resource Graph (ARG) query and returns the flattened result rows.

If `-Query` is not provided, the default query is a lightweight `resources | project ...` projection intended for inventory scenarios. The default projection includes common identification fields plus additional columns used by the Analyzer inventory worksheet (when present in ARG for a given resource): `kind`, `managedBy`, `sku`, `plan`, `zones`, `version`.

Inventory SKU notes:

- For Virtual Machines (`microsoft.compute/virtualmachines`), `sku` is derived from `properties.hardwareProfile.vmSize` and projected as `sku.name`.
- For some resource types that keep SKU under `properties.sku` (instead of the top-level `sku` field), the default query falls back to `properties.sku` when the top-level `sku` is null.

Inventory Version notes:

The `version` column extracts the software/engine version from `properties` for supported resource types. The following resource types have version extraction:

| Resource Type | Version Source |
|---|---|
| `microsoft.containerservice/managedclusters` (AKS) | `properties.currentKubernetesVersion` |
| `microsoft.dbformysql/flexibleservers` | `properties.version` |
| `microsoft.dbforpostgresql/flexibleservers` | `properties.version` |
| `microsoft.dbformysql/servers` | `properties.version` |
| `microsoft.dbforpostgresql/servers` | `properties.version` |
| `microsoft.dbformariadb/servers` | `properties.version` |
| `microsoft.sql/servers` | `properties.version` |
| `microsoft.cache/redis` | `properties.redisVersion` |
| `microsoft.cache/redisenterprise` | `properties.redisVersion` |
| `microsoft.documentdb/databaseaccounts` (Cosmos DB) | `properties.mongoServerVersion` |
| `microsoft.hdinsight/clusters` | `properties.clusterVersion` |
| `microsoft.kusto/clusters` (Data Explorer) | `properties.engineType` |

For resource types not listed above, `version` will be an empty string.

## EXAMPLES

### Example 1

```powershell
PS C:\> {{ Add example code here }}
```

{{ Add example description here }}

## PARAMETERS

### -query

{{ Fill query Description }}

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -subscriptionIds

{{ Fill subscriptionIds Description }}

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 0
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -ProgressAction

{{ Fill ProgressAction Description }}

```yaml
Type: ActionPreference
Parameter Sets: (All)
Aliases: proga

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters

This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

### None

## OUTPUTS

### System.Object

## NOTES

## RELATED LINKS
