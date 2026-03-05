---
external help file: utils-help.xml
Module Name: utils
online version:
schema: 2.0.0
---

# Format-WAFKeyValueObjectForDisplay

## SYNOPSIS

Formats ARG dynamic/complex values (objects/arrays) into readable display strings.

## SYNTAX

```text
Format-WAFKeyValueObjectForDisplay [[-Value] <Object>] [[-PreferredKeyOrder] <String[]>] [-Multiline]
 [-TrailingSemicolon] [<CommonParameters>]
```

## DESCRIPTION

Azure Resource Graph (ARG) can return complex types (for example `sku`, `plan`, `zones`) that PowerShell would normally render as `@{...}`.

For robustness, this function includes safeguards against unexpectedly deep or self-referential objects (which can otherwise cause PowerShell call-depth overflow).
When diagnostics is enabled (the environment variable `WARA_DIAGNOSTICS_QUERY_DUMP_DIR` is set), the function may emit a small JSON “format issue” dump into that directory to help identify the specific resource/field that contains unexpected data.

This helper converts:

- `null` / empty / `'null'` strings -> `$null`
- Arrays -> a semicolon-delimited string (example: `1;2`)
- Objects / dictionaries -> `key=value` pairs, optionally multi-line and with an optional trailing `;` per line.

This function is used by `Invoke-WAFQuery` to normalize inventory fields for JSON and Excel output.

## EXAMPLES

### Example 1: Format a SKU object for Excel display

```powershell
$sku = [pscustomobject]@{ name = 'Standard_B1ls'; tier = 'Standard'; capacity = 2 }
Format-WAFKeyValueObjectForDisplay -Value $sku -Multiline -TrailingSemicolon
```

## PARAMETERS

### -Value

The value to format. Can be a string, array, object, or dictionary.

```yaml
Type: Object
Required: False
Position: 0
```

### -PreferredKeyOrder

Keys to emit first when formatting objects.

```yaml
Type: String[]
Required: False
```

### -Multiline

If set, outputs one `key=value` per line. Otherwise joins as a single line.

```yaml
Type: SwitchParameter
Required: False
```

### -TrailingSemicolon

If set (typically with `-Multiline`), adds a trailing `;` to each output line.

```yaml
Type: SwitchParameter
Required: False
```

## OUTPUTS

### System.String

## NOTES

This is a display helper; it does not preserve original types.
