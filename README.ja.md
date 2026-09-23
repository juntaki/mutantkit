<img src="assets/logo.png" alt="MutantKit logo" width="96">

# MutantKit

[English](README.md) | 日本語

[![CI](https://github.com/juntaki/mutantkit/actions/workflows/ci.yml/badge.svg)](https://github.com/juntaki/mutantkit/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/juntaki/mutantkit/graph/badge.svg)](https://codecov.io/gh/juntaki/mutantkit)
[![Quality Gate Status](https://sonarcloud.io/api/project_badges/measure?project=juntaki_mutantkit&metric=alert_status)](https://sonarcloud.io/summary/new_code?id=juntaki_mutantkit)
[![CodeQL](https://github.com/juntaki/mutantkit/actions/workflows/codeql.yml/badge.svg)](https://github.com/juntaki/mutantkit/actions/workflows/codeql.yml)
[![OpenSSF Scorecard](https://api.securityscorecards.dev/projects/github.com/juntaki/mutantkit/badge)](https://securityscorecards.dev/viewer/?uri=github.com/juntaki/mutantkit)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/14602/badge)](https://www.bestpractices.dev/projects/14602)
[![GitHub release](https://img.shields.io/github/v/release/juntaki/mutantkit)](https://github.com/juntaki/mutantkit/releases)
[![License](https://img.shields.io/github/license/juntaki/mutantkit)](LICENSE)

**Swift / Appleプラットフォーム向けの、実際に適用・実行されたmutationだけを評価するミューテーションテストツールです。**

MutantKitはコードに小さな変更（mutant）を加え、それをテストが検出できるかを調べます。mutationが実際のバイナリへ反映され、変更後のコードが実行されたことを確認してから結果を評価します。

## まず試す

### 必要なもの

* macOS 14以降
* Apple Silicon Mac
* Swift 6.0以降
* SwiftPMプロジェクト、またはXcode project / workspace
* 実行可能なテスト

### CLIで直接使う

MutantKitをインストールします。

```bash
brew install juntaki/mutantkit/mutantkit
```

プロジェクトのルートディレクトリで、そのまま次を実行します。

```bash
mutantkit setup
mutantkit dry-run
mutantkit plan --output plan.json
mutantkit run --plan plan.json
```

それぞれの役割は次のとおりです。

| コマンド                | 内容                                         |
| ------------------- | ------------------------------------------ |
| `mutantkit setup`   | プロジェクト、scheme、test targetを検出して設定ファイルを作成します |
| `mutantkit dry-run` | mutationを適用せず、通常のbuild/testが成功することを確認します   |
| `mutantkit plan`    | 適用するmutationの一覧を作成します                      |
| `mutantkit run`     | mutationを適用し、テストが検出できるかを調べます               |

`run`の結果をCIの失敗条件にする場合は、`--fail-on-survivors`を追加します。

```bash
mutantkit run --plan plan.json --fail-on-survivors
```

### Claude Codeに任せる

MutantKit本体とClaude Code pluginをインストールします。

```bash
brew install juntaki/mutantkit/mutantkit

claude plugin marketplace add juntaki/mutantkit
claude plugin install mutantkit@mutantkit
```

対象プロジェクトのルートでClaude Codeを起動します。

```bash
claude
```

そのまま、例えば次のように依頼できます。

```text
このプロジェクトでMutantKitをセットアップして。
まずsetupとdry-runで環境を確認し、小さなmutation budgetで実行して、
integrityを確認した上でsurvivorを分析して。
```

pluginに含まれるMutantKit skillが、`setup → dry-run → plan → run`の手順、integrityの確認、survivorの分析、reproduceまでをagentに指示します。

pluginを更新する場合：

```bash
claude plugin marketplace update mutantkit
claude plugin update mutantkit
```

### Codexに任せる

MutantKit本体とCodex pluginをインストールします。

```bash
brew install juntaki/mutantkit/mutantkit

codex plugin marketplace add juntaki/mutantkit
codex plugin add mutantkit@mutantkit
```

対象プロジェクトのルートでCodexを起動します。

```bash
codex
```

例えば次のように依頼できます。

```text
このプロジェクトでMutantKitをセットアップして。
まずsetupとdry-runで環境を確認し、小さなmutation budgetで実行して、
integrityを確認した上でsurvivorを分析して。
```

Claude CodeとCodexのpluginは、どちらも同じ`skills/mutantkit/SKILL.md`を参照します。

より詳しいagent連携やmanual setupについては[docs/agents.md](docs/agents.md)を参照してください。

### 実行後に確認するもの

実行が完了すると、mutationごとに次のような結果が表示されます。

| 結果                      | 意味                                |
| ----------------------- | --------------------------------- |
| `killed`                | mutationによる変更をテストが検出した            |
| `survived`              | mutationされたコードまで実行されたが、テストはすべて通った |
| `noCoverage`            | mutationされたコードをテストが実行していない        |
| `notApplied`            | mutationを安全に適用できなかった              |
| `baselineMismatch`      | 実行対象が検証済みbaselineと一致しない           |
| `infrastructureFailure` | 実行環境側の問題で判定できない                   |

`survived`は、テストが弱くmutationを検出できなかった可能性があります。`noCoverage`は、そもそもmutationされたコードがテストから実行されていないことを示します。

結果を詳しく調べる場合は、mutation IDを指定します。

```bash
mutantkit inspect mut_a1b2c3d4e5f6a7b8
mutantkit reproduce mut_a1b2c3d4e5f6a7b8
```

`inspect`ではsource diff、operator、実行されたtest、outcome、command、evidenceを確認できます。`reproduce`では、そのmutationだけを再実行できます。

## なぜMutantKitなのか

ミューテーションテストでは、mutationがソースへ適用されてもバイナリへ反映されていなかったり、古いbuildやSimulator crashなどのインフラ障害がテスト結果として扱われたりすることがあります。

MutantKitは、mutationの適用と実行を検証します。確認できないmutantを`killed`や`survived`として推測せず、fail-closedで扱います。

* compiled codeをbaselineと比較し、mutationが実行対象へ反映されたことを確認
* coverageを使い、実際に実行されたmutationと未到達のmutationを区別
* evidenceを整合できない結果は通常のscoreへ含めない

現在の最新リリースは `v1.0.3` です。SwiftPMとXcode project / workspace、isolatedとschemata実行、CI gating、coverage-based test selection、caching、sharding、resumable runsに対応しています。既定で有効なoperatorは6種類で、残りは検証が進み次第、順次追加していく方針です。詳しくは[Operators](docs/operators.md)と後述の「対応状況」を参照してください。

## 結果の見方

**Tested**

```text
killed / (killed + survived)
```

実際にテストされたmutationに対する検出率です。

**Effective**

```text
killed / (killed + survived + noCoverage)
```

coverage gapを含むテストスイート全体の検出率です。

`notApplied`、`baselineMismatch`、`infrastructureFailure`は、通常のmutation scoreへ含めず、別の問題として扱います。

## 主な特徴

* **Verified mutation activation** — mutationが実行対象binaryへ反映されたことを確認
* **Fail-closed integrity model** — 証明できない結果をscoreへ含めない
* **SwiftPM / Xcode対応** — Swift PackageとXcode project / workspaceに対応
* **Coverage-based test selection** — mutationに関係するテストへ絞り込み
* **Resumable / shardable runs** — plan、checkpoint、shardingによる分割・再開
* **Actionable survivors** — diff、再現コマンド、修正候補を確認
* **Coding Agent integration** — Claude Code / Codexからskillを使って操作可能
* **CI quality gates** — score、regression、新しいsurvivorをCIで検証

## 対応状況

| 対象                        | 状況                                              |
| ------------------------- | ----------------------------------------------- |
| SwiftPM（macOS）            | Supported                                       |
| SwiftPM（Apple platforms）  | Supported                                       |
| Xcode project / workspace | Supported                                       |
| iOS Simulator             | Supported                                       |
| Isolated execution        | Supported                                       |
| Schemata execution        | 対応operator / project種別でSupported                |
| XCUITest                  | Xcode + iOS Simulator + isolated modeでSupported |
| 実機                        | schemataはUnsupported。isolatedは未検証               |
| tvOS / watchOS / visionOS | isolatedはbest-effort、schemataはUnsupported       |
| Apple固有mutation operator  | 一部validated opt-in、一部experimental               |

より詳しい判断基準（isolated/schemataの実行時間比較を含む）は[docs/apple-support-matrix.md](docs/apple-support-matrix.md)を参照してください。

## インストール

### Homebrew

```bash
brew install juntaki/mutantkit/mutantkit
```

prebuilt binaryをmacOS 14以降のApple Siliconへインストールします。

### リリースバイナリを直接使う

```bash
curl -LO https://github.com/juntaki/mutantkit/releases/latest/download/mutantkit-macos-arm64.tar.gz
curl -LO https://github.com/juntaki/mutantkit/releases/latest/download/SHA256SUMS
shasum -a 256 -c SHA256SUMS
tar xzf mutantkit-macos-arm64.tar.gz
```

### ソースからビルドする

Swift 6.0以降が必要です。

```bash
git clone https://github.com/juntaki/mutantkit.git
cd mutantkit
swift build -c release
```

binaryは`.build/release/mutantkit`に生成されます。

### アップグレード / アンインストール

```bash
brew upgrade mutantkit
brew uninstall mutantkit
mutantkit --version
```

## 基本ワークフロー

```text
setup → dry-run → plan → run
```

### プロジェクトを設定する

```bash
mutantkit setup
```

project種別、scheme、test targetなどを検出し、`mutantkit.yml`を作成します。

設定を確認する場合：

```bash
mutantkit doctor
```

`setup`で自動検出できないschemeやtest targetがある場合は、生成された`mutantkit.yml`を編集してから再度`doctor`を実行します。

### baselineを確認する

```bash
mutantkit dry-run
```

mutationを適用せず、本番runと同じ設定でbuild/testします。

### Mutation Planを作る

```bash
mutantkit plan --output plan.json
```

Mutation Planは、実行するmutationの一覧を保存したJSONファイルです。後から同じplanを使って再実行したり、複数のworkerへ分割したりできます。

### 実行する

```bash
mutantkit run --plan plan.json
```

survivorがある場合にcommandをfailureにするには、次のように実行します。

```bash
mutantkit run --plan plan.json --fail-on-survivors
```

## Coding Agent

Quick Startのpluginを利用すると、agentにMutantKitの操作と結果解釈を任せられます。

skillは次のファイルをsingle source of truthとして、Claude Code / Codex双方から利用します。

```text
skills/mutantkit/SKILL.md
```

agent向けには、単に`run`を実行するだけではなく、

```text
setup
↓
dry-run
↓
small-budget run
↓
trust / integrity確認
↓
survivor分析
↓
inspect / reproduce
↓
fix-plan / next
```

というworkflowを定義しています。

既存reportをagentに解析させる場合も、raw scoreだけを渡すのではなく次のcommandを利用できます。

```bash
mutantkit trust --report report.json
mutantkit survivors --report report.json
mutantkit fix-plan --report report.json --format agent
mutantkit next --report report.json --format agent
```

pluginを使わず、skillを手動でClaude Codeや`AGENTS.md`へ導入する方法は[docs/agents.md](docs/agents.md)を参照してください。

## CI

### GitHub Actions

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0

- uses: juntaki/mutantkit@<release-tag>
  with:
    mode: ci
    diff: origin/main
```

`mode: ci`では、`doctor → plan → run → gate`を実行します。policyは`mutantkit.yml`で管理します。

### 他のCIで使う

```bash
mutantkit plan --output plan.json
mutantkit shard plan.json --count 8
mutantkit run --plan plan.3.json --output results.3.json --no-history
mutantkit merge results/*.json
```

checkpointにより、中断したrunを再開できます。

### Quality Gate

```bash
mutantkit gate --report report.json \
  --baseline main-report.json \
  --minimum-effective 70 \
  --regression-maximum-drop 2 \
  --new-survivors-maximum 0
```

score thresholdだけでなく、baselineからのregressionや新しいsurvivorの追加もmerge条件にできます。

## survivorを調べて修正する

個別のsurvivorを調べる場合：

```bash
mutantkit inspect mut_a1b2c3d4e5f6a7b8
mutantkit reproduce mut_a1b2c3d4e5f6a7b8
```

report全体を調べる場合：

```bash
mutantkit trust --report report.json
mutantkit survivors --report report.json
mutantkit fix-plan --report report.json
mutantkit next --report report.json
```

coding agent向けの出力には`--format agent`を使えます。

```bash
mutantkit fix-plan --report report.json --format agent
mutantkit next --report report.json --format agent
```

## 仕組みと信頼性モデル

* mutation後のcompiled codeをbaselineと比較し、activationを検証します。
* Mutation Planをsource of truthとして、sharding、resume、reproduce間でidentityを維持します。
* staleなsourceに対して近いoffsetへ推測で適用せず、解決できなければ`notApplied`にします。
* Xcodeでは`.xcresult`、SwiftPM/macOSではprocess statusとstructured xUnit reportを使います。
* timeoutしたprocess groupと追跡可能なdescendant processを回収します。
* evidenceを整合できない結果は通常のscoreへ含めません。

## 対象コードの選び方

mutation testingは、unit testで振る舞いを明確に固定できるdomain / business logicに適しています。

OSやhardwareとの薄いboundary、UI glue、integration shimなどは対象外にした方がよい場合があります。

```yaml
sources:
  exclude:
    - Sources/AudioHAL/**
    - Sources/SystemIntegration/**
```

## 特定のmutationを抑制する

```swift
// mutantkit:disable-next-line swift.core.relational-operator-replacement
if index < count { ... }

if index < count { ... } // mutantkit:disable-line swift.core.relational-operator-replacement
```

または`.mutantkitignore`を利用できます。

```text
id:mut_a1b2c3d4e5f6a7b8
operator:swift.core.logical-connector-replacement
file:Sources/Generated/**
line:Sources/Foo.swift:42
```

suppressed mutantは理由付きで`plan.skipped`に残ります。

```text
discovered == planned + skipped
```

## レポートと連携

Mutation Testing Elements、self-contained HTML、Markdown CI summary、GitHub Actions annotations、Sonar generic issues、SARIF 2.1.0などへ出力できます。

## ドキュメント

* [Evidence model](docs/evidence-model.md)
* [Operators](docs/operators.md)
* [CI](docs/ci.md)
* [Apple support matrix](docs/apple-support-matrix.md)
* [Agents](docs/agents.md)
* [ADR-0002](ADR/0002-the-mutation-plan-is-the-source-of-truth.md)

## Contributing

* [Bug報告・機能要望](https://github.com/juntaki/mutantkit/issues)
* [Contributing guide](CONTRIBUTING.md)
* security vulnerabilityについては[SECURITY.md](SECURITY.md)を参照してください

## ライセンス

Apache 2.0。

[LICENSE](LICENSE)、[THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES)、[SECURITY.md](SECURITY.md)を参照してください。
