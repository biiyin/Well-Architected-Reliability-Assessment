# WARA 模块在用户环境的安装与使用（中文）

本文档用于**定制版本**的 WARA：用户不会从 PowerShell Gallery 安装，也**不需要拿到源代码/Git 仓库**；用户仅使用你（开发者）提供的**模块包（zip）**完成导入，并执行 WARA 数据收集（Collector）。

适用场景：

- 用户可以访问 Internet（可登录 Azure、可访问依赖下载源等）
- 但用户必须使用你提供的 **定制版 WARA**（而不是 Gallery 上的公开版本）

## 0. 前置条件

- PowerShell **7.4+**（模块清单要求 `PowerShellVersion = 7.4`）
- 依赖模块（导入 WARA 前建议先安装/更新）：
  - `Az.Accounts` **3.0.0+**
  - `Az.ResourceGraph` **1.0.0+**

安装依赖示例：

```powershell
Install-Module -Name Az.Accounts -Scope CurrentUser
Install-Module -Name Az.ResourceGraph -Scope CurrentUser
```

> 说明
>
> - 本文重点覆盖“数据收集（Start-WARACollector）”。
> - `Start-WARAReport` 通常需要在 Windows 且本机安装 Office（Excel/PowerPoint）后才能生成报告；Collector/Analyzer 可在支持 PowerShell 的平台运行（以仓库 README 为准）。

## 1. 开发者需要提供什么（交付清单）

为了让用户在不依赖 Gallery 的情况下稳定使用你的定制版，建议你交付以下内容：

- **模块包（必需）**：一个可直接导入的模块目录（推荐压缩为 zip）。
  - 目录内至少包含 `wara.psd1`、`wara.psm1` 以及 `analyzer/`、`collector/` 等嵌套模块（NestedModules）。
  - 推荐交付形式：`WARA-custom-<version>.zip`
- **版本与来源说明（必需）**：
  - 定制版版本号（对应 manifest 的 `ModuleVersion`）
  - 构建时间（以及可选的内部构建编号）
  - 适用的 PowerShell 版本（7.4+）与依赖模块版本
- **完整性校验（推荐）**：zip 的 SHA256 校验值，便于用户验证文件未被篡改
- **配置样例（推荐）**：一个可直接改值使用的 config 文件模板（例如仓库里已有 `docs/wara/configfile.example`）

### 1.1 如何从定制化代码生成“可交付模块包”（建议流程）

下面流程的目标是：你基于定制代码生成一个**模块包 zip**，交给客户后客户只需解压并导入即可运行 Collector；客户无需获取源代码仓库。

#### Step 1：在开发者侧完成定制代码修改

你通常会在模块目录内改动（示例）：

- `src/modules/wara/wara.psm1`
- `src/modules/wara/**`（collector/analyzer/utils 等嵌套模块目录）

#### Step 2：更新模块版本号（强烈建议）

打开 `src/modules/wara/wara.psd1`，调整：

- `ModuleVersion = '<你的定制版本号>'`

推荐做法：在你定制分支上按语义化版本递增（例如 `1.0.6` → `1.0.6-custom.1` 不一定被 PowerShell 版本比较接受；更稳妥的是直接提升为 `1.0.7`、`1.0.8` 这类纯数字版本）。

> 为什么要升级版本号
>
> - Collector 会用 `Find-Module` 做版本检查。
> - 若客户环境可查询到更高版本（例如仍保留 PSGallery），而你的定制版版本号更低，Collector 可能会被判定“过期”并停止。

#### Step 3：生成交付目录结构（WARA\\{version}）

PowerShell 习惯的模块目录结构如下（交付给客户时建议保持这个结构）：

```text
WARA\
  {version}\
    wara.psd1
    wara.psm1
    analyzer\...
    collector\...
    utils\...
    ...
```

在你的开发机上，可以新建一个“交付输出目录”（示例：`dist`），然后把 `src/modules/wara` 的**全部内容**拷贝进去。

示例命令（PowerShell）：

```powershell
$version = (Import-PowerShellDataFile .\src\modules\wara\wara.psd1).ModuleVersion

New-Item -ItemType Directory -Force -Path .\dist\WARA\$version | Out-Null
Copy-Item -Recurse -Force .\src\modules\wara\* .\dist\WARA\$version\
```

#### Step 4（可选）：脚本签名

如果客户环境执行策略较严格（例如需要签名脚本），你可以对交付目录中的 `.ps1/.psm1` 进行签名（需要你拥有代码签名证书）。

> 说明：是否需要签名取决于客户的执行策略与安全要求。本文不强制。

#### Step 5：打包为 zip

将整个 `dist\WARA` 目录打包（确保 zip 顶层是 `WARA/` 目录）：

```powershell
$zipName = "WARA-custom-$version.zip"
if (Test-Path .\dist\$zipName) { Remove-Item .\dist\$zipName -Force }
Compress-Archive -Path .\dist\WARA -DestinationPath .\dist\$zipName
```

#### Step 6：生成 SHA256 校验值

```powershell
Get-FileHash -Algorithm SHA256 .\dist\$zipName | Format-List
```

#### Step 7：把“运行所需材料”一起交付给客户

建议你交付一组文件（同一个交付包/邮件/共享链接）：

- `WARA-custom-<version>.zip`
- `WARA-custom-<version>.zip.sha256.txt`（或直接在交付说明里写出 SHA256）
- `configfile.example`（让客户复制成 `config.txt` 改值即可）
- 本文档（或一份更短的客户执行指引，包含：导入、登录、Start-WARACollector 示例）

> 关键注意：定制版的版本号（`ModuleVersion`）
>
> - `Start-WARACollector` 在执行时会用 `Find-Module` 做“是否有更新版本”的检查。
> - 如果用户环境能访问 Internet 且配置了 PSGallery，那么 `Find-Module WARA` 可能返回 Gallery 上的公开版本。
> - 若你的定制版 `ModuleVersion` **小于** Gallery 版本，Collector 会提示“模块过期”并直接停止。
> - 因此交付定制版时，建议将 `ModuleVersion` 设置为不低于 Gallery 的版本（例如在你定制分支上递增版本号），或提供你自己的可查询 Repository（即使用户不从它安装，也能让 `Find-Module` 返回一致版本）。

## 2. 用户如何安装/导入你的定制版（不使用 Gallery）

推荐方式：将你提供的模块包解压后，拷贝到 PowerShell 模块目录（`$env:PSModulePath`），然后 `Import-Module WARA`。

> 建议
>
> - 为避免和 Gallery 的 `WARA` 混用，推荐让用户**只保留一个来源**（你的定制版）。

### 拷贝到 PSModulePath（推荐）

1. 用户解压你提供的 zip，得到模块目录（示例结构）：

- `WARA\1.0.6\wara.psd1`
- `WARA\1.0.6\wara.psm1`
- `WARA\1.0.6\collector\collector.psd1`

1. 拷贝到 PowerShell 的模块搜索路径之一（`$env:PSModulePath`）。常见路径：

- Windows（当前用户）：`$HOME\Documents\PowerShell\Modules`
- Windows（所有用户）：`C:\Program Files\PowerShell\Modules`
- Linux/macOS（当前用户）：`$HOME/.local/share/powershell/Modules`

查看实际路径：

```powershell
$env:PSModulePath -split [IO.Path]::PathSeparator
```

1. 导入模块：

```powershell
Import-Module -Name WARA -Force
```

### 避免与 Gallery 版本混用（强烈建议）

让用户先确认当前机器上是否存在其它来源的 WARA：

```powershell
Get-Module -ListAvailable WARA | Select-Object Name, Version, Path
```

如果存在多个路径/多个版本，务必让用户明确只使用你的定制版（例如卸载/移除旧目录，或仅用“方式 B”路径导入）。

如果用户之前通过 Gallery 安装过公开版，可以先卸载（按需）：

```powershell
# 仅在确认该模块来自 Gallery 且不再需要时执行
# Uninstall-Module -Name WARA -AllVersions
```

## 3. 导入后快速验证

```powershell
Get-Module WARA
Get-Command -Name Start-WARACollector, Start-WARAAnalyzer, Start-WARAReport
```

## 4. 指导用户完成 WARA 数据收集（Start-WARACollector）

### 4.1 准备信息（用户侧）

你需要指导用户准备以下最小信息：

- `TenantID`（租户 GUID）
- 范围：
  - `SubscriptionIds`（推荐）或
  - `ResourceGroups`（可选，精确到资源组）

> 权限建议
>
> - 至少需要对目标订阅/资源组具备读取权限，并能访问 Azure Resource Graph。

### 4.2 登录 Azure

WARA 依赖 Az 模块。通常让用户先登录：

```powershell
Connect-AzAccount -Tenant <TenantId>
```

如果用户使用多订阅，也可以（可选）设置默认上下文：

```powershell
# Set-AzContext -Subscription <subscriptionId>
```

### 4.3 运行 Collector（最小示例）

```powershell
Start-WARACollector `
  -TenantID "00000000-0000-0000-0000-000000000000" `
  -SubscriptionIds "/subscriptions/00000000-0000-0000-0000-000000000000"
```

输出：Collector 会在**当前工作目录**生成一个 JSON 文件（文件名带时间戳）。你可以指导用户在一个固定目录执行，例如：

```powershell
New-Item -ItemType Directory -Force -Path C:\WARA | Out-Null
Set-Location C:\WARA
Start-WARACollector -TenantID "<TenantId>" -SubscriptionIds "/subscriptions/<subId>"
```

### 4.4 常见扩展：资源组/标签过滤与专业化工作负载

- 按资源组范围：

```powershell
Start-WARACollector -TenantID "<TenantId>" -ResourceGroups "/subscriptions/<subId>/resourceGroups/<rgName>"
```

- 按标签过滤（示例格式以实际模块校验规则为准）：

```powershell
Start-WARACollector -TenantID "<TenantId>" -SubscriptionIds "/subscriptions/<subId>" -Tags "env=~prod","application=~demoapp1"
```

- 专业化工作负载（示例）：

```powershell
Start-WARACollector -TenantID "<TenantId>" -SubscriptionIds "/subscriptions/<subId>" -SAP -AVD -HPC
```

### 4.5 用配置文件运行（推荐给生产/可重复执行）

如果你希望用户更稳定地重复执行，建议你提供一个 config 文件模板，让用户只改几个值。

配置文件格式要点（对应 `Import-WAFConfigFileData` 的解析规则）：

- 用 `[sectionName]` 分段（大小写不敏感）
- 每个 section 下**每一行就是一个值**（不是 `key=value` 的 ini 风格；只有 `[tags]` 区域才是 `key=~value` 这种形式）
- 空行会被忽略；包含 `#` 的行会被忽略（因此不要在值里包含 `#`）

多个订阅 / 多个资源组的写法：

- 在 `[subscriptionIds]` 下每行一个订阅 ID
- 在 `[resourcegroups]` 下每行一个资源组 ID

示例片段（多个 RG）：

```text
[resourcegroups]
/subscriptions/<subId>/resourceGroups/Demo1-RG
/subscriptions/<subId>/resourceGroups/Demo2-RG
```

示例片段（多个订阅）：

```text
[subscriptionIds]
/subscriptions/<subId1>
/subscriptions/<subId2>
```

示例片段（tags）：

```text
[tags]
env=~prod
application=~demoapp1
```

```powershell
Start-WARACollector -ConfigFile "C:\path\to\config.txt"
```

> 提示
>
> - 你可以把仓库里的 `docs/wara/configfile.example` 作为交付模板的一部分。

## 5. 常见问题（Troubleshooting）

- 导入失败/提示缺少依赖：先安装 `Az.Accounts`、`Az.ResourceGraph`，再 `Import-Module WARA -Force`。
- 执行策略阻止导入（Windows）：以组织策略为准；常见做法是将当前用户设置为 `RemoteSigned`：

  ```powershell
  Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
  ```

- Collector 提示模块过期/需要更新：检查你的定制版 `ModuleVersion` 是否低于用户环境可查询到的版本（例如用户仍保留了可访问的 PSGallery 源，或环境内有其它仓库源返回了更高版本）。从开发者角度，建议提升定制版版本号并重新交付。
- Collector 报 `Find-Module` 相关错误：说明用户环境没有可用的 PowerShell Repository 可查询。若你不希望用户使用 Gallery，也建议至少提供一个可查询的内部 Repository（或在受控网络下允许查询你指定的源）。
