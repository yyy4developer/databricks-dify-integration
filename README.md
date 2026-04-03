# Databricks x Dify Integration Patterns

Databricks と Dify の連携パターンを検証するためのリポジトリです。
Databricksにある程度詳しい方が、ガイドに従って自走でhands-on検証できることを目指しています。

## Dify Cloud版 vs Self-Host版

Difyには複数のデプロイ形態があります。**本リポジトリはSelf-Host（Community Edition）を対象としています。**

| | Cloud版（SaaS） | Self-Host Community版（本検証対象） |
|---|---------|----------------------|
| **デプロイ** | [cloud.dify.ai](https://cloud.dify.ai) | Docker Compose で自前環境に構築 |
| **費用** | Sandbox（無料/200msg）〜 Team（$159/月/10,000msg） | 無料（インフラ費用のみ） |
| **ワークスペース** | プランにより1〜複数 | 1（制限なし） |
| **チームメンバー** | Sandbox: 1人 / Pro: 3人 / Team: 50人 | 制限なし（インフラ依存） |
| **アプリ数** | Sandbox: 5 / Pro: 50 / Team: 200 | 制限なし |
| **ナレッジストレージ** | Sandbox: 50MB / Pro: 5GB / Team: 20GB | 制限なし |
| **カスタマイズ** | プラグインのみ | ソースコード修正も可能 |
| **SSRFプロキシ** | 変更不可 | `squid.conf.template` でドメイン許可を追加可能 |
| **データ主権** | Dify社インフラ経由 | 全データが自社環境内に留まる |
| **Databricks接続** | IPが動的 → IP ACL制限のあるWSに接続困難 | 自社NW内 → VPN/IP ACL問題なし |

> **Self-Hostを選択した理由**:
> - Databricks連携ではSSRFプロキシのカスタマイズ（ドメイン許可追加）が必須
> - IP ACL付きワークスペースへの安定接続にはSelf-Hostが適切
> - トレーシング（観測性）の検証でDify内部コードの修正が必要なケースがある
> - 本番環境ではデータ主権の観点からもSelf-Hostが推奨される
>
> Cloud版でもSSRFプロキシ以外の連携パターン（Pattern 1 LLM, Pattern 3 MCP等）はIP ACLなしのワークスペースで利用可能です。

## 連携パターン一覧

| # | パターン | 方向 | Notebook |
|---|---------|------|----------|
| 0 | データセットアップ | — | `00_data_setup` |
| 1 | LLMモデル連携 | Dify→DB | `01_llm_integration` |
| 2 | HTTP API連携 | Dify→DB | `02_http_api_integration` |
| 3 | MCP Server連携 | Dify→DB | `03_mcp_integration` |
| 4 | RAGナレッジ連携 | Dify→DB | `04_rag_vector_search` |
| 5 | Databricksオーケストレーター | DB→Dify | `05_databricks_orchestrator` |
| 6 | 観測性・MLOps連携 | 双方向 | `06_observability` |

> ビジネス向けサマリは [docs/summary.md](docs/summary.md)、技術的知見の詳細は [docs/findings.md](docs/findings.md) を参照。

## 前提条件

- Databricks Workspace（Unity Catalog有効）
- Docker / Docker Compose
- VPN接続（IP ACL付きワークスペースの場合）

## セットアップ手順

### 1. リポジトリのクローン

```bash
git clone --recurse-submodules https://github.com/yyy4developer/databricks-dify-integration.git
cd databricks-dify-integration
```

### 2. 設定ファイルの編集

```bash
# 設定ファイルをexampleからコピーして編集
cp config.yaml.example config.yaml
cp databricks.yml.example databricks.yml
# config.yaml: catalog, schema, endpoint名等を設定
# databricks.yml: workspace host を設定
```

`config.yaml` の主要パラメータ:

| パラメータ | 説明 |
|-----------|------|
| `catalog` / `schema` | Unity Catalog のカタログ・スキーマ名 |
| `llm_endpoint_name` | LLMモデル名（FMAPI/AI Gateway） |
| `ai_gateway_url` | AI Gateway URL |
| `vector_search_endpoint_name` | Vector Search Endpoint名 |
| `mlflow_experiment_name` | MLflow Experiment名 |
| `obs_schema` / `delta_sync_table` | 観測性用スキーマ・テーブル名 |
| `genie_space_id` | Genie Space ID（Pattern 2/3で使用） |

### 3. Difyの起動と初期設定

```bash
cd dify/docker
cp .env.example .env
docker compose up -d
```

http://localhost にアクセスし、以下を実施:

1. **管理者アカウント作成**: http://localhost/install
2. **プラグインインストール**: Settings → Plugin → Marketplace
   - `OpenAI-API-compatible`（Pattern 1, 2, 4, 6）
   - `MCP SSE`（Pattern 3、v0.2.3以上）
3. **Model Provider設定**: Settings → Model Provider → OpenAI-API-compatible
   - Model Name / API endpoint URL / API Key（PAT）/ Completion mode: Chat

> SSRFプロキシ: `.cloud.databricks.com` と `.ai-gateway.cloud.databricks.com` は許可済み。
> カスタム変更の詳細は [CUSTOMIZATIONS.md](https://github.com/yyy4developer/dify/blob/databricks-integration/CUSTOMIZATIONS.md) を参照。

4. **Claude/Gemini対応パッチ（オプション）**: GPT系以外のモデルを使う場合に実行
   ```bash
   ./scripts/patch-dify-plugin.sh
   ```
   > GPT系モデルのみ利用する場合は不要です。詳細は [docs/findings.md](docs/findings.md) のセクション2を参照。

### 4. Databricksリソースの構築

```bash
databricks bundle deploy
```

Databricks Workspaceで `notebooks/00_data_setup.ipynb` を実行。

### 5. Hands-on開始

`notebooks/01_llm_integration.ipynb` から順に実施。各notebookに必要なリソース構築手順が含まれています。

### 6. DSLインポート（オプション）

`dsl/` にDifyアプリ定義ファイルがあります。Dify UI → **Studio** → **Import DSL File** でインポート可能。
`dsl/optional/` にはKA/MAS/Agent用DSLもあります（構築済み環境向け）。

## プロジェクト構成

```
.
├── config.yaml                 # パラメータ設定（各自で編集）
├── databricks.yml              # Databricks Asset Bundle設定
├── notebooks/                  # Hands-on Notebooks
│   ├── _config.ipynb           # 共通設定（config.yaml読み込み）
│   ├── 00_data_setup.ipynb     # Databricksリソース構築
│   ├── 01-06_*.ipynb           # 各連携パターン
│   └── 99_cleanup.ipynb        # リソースクリーンアップ
├── dsl/                        # Difyアプリ定義（DSLエクスポート）
│   └── optional/               # KA/MAS/Agent用（構築済み環境向け）
├── scripts/                    # ユーティリティスクリプト（プラグインパッチ等）
├── middleware/                  # Pattern 4: External Knowledge API中間サーバー
├── pdfs/                       # PDFドキュメント（Volume uploadに使用）
├── dify/                       # Dify OSS (git submodule: yyy4developer/dify)
└── docs/
    ├── summary.md              # ビジネス向けサマリ
    └── findings.md             # 技術的知見（検証結果詳細）
```

## トラブルシューティング

| 問題 | 対処 |
|------|------|
| プラグインインストール失敗 | `docker compose restart ssrf_proxy plugin_daemon` |
| Databricks 403 | VPN接続確認、IP ACLにIP追加 |
| "Invalid encrypted data" | Dify 1.13以降はパスワードをBase64エンコード |
| Redis RDBエラー | `docker exec docker-redis-1 redis-cli CONFIG SET stop-writes-on-bgsave-error no` |

## クリーンアップ

```bash
# Databricksリソース: notebooks/99_cleanup.ipynb を実行
# Dify停止:
cd dify/docker && docker compose down
```
