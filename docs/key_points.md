# Ricoh Agent Dev Hands-on キーポイント集

スライド作成・提案資料用のポイントを蓄積するファイル。

---

## 1. Difyアプリ乱立問題とDatabricksによる解決

### 現状の課題

Difyの各アプリ（DSLファイル）にモデル・ツール・ナレッジが個別に埋め込まれている。

```
DSL(モデル+ツール+ナレッジ)   ← 全部バラバラ
DSL(モデル+ツール+ナレッジ)
DSL(モデル+ツール+ナレッジ)
```

- アプリごとにモデル設定が重複
- ツール・ナレッジが散在し再利用できない
- 誰が何を作ったか把握できない（ガバナンス欠如）

### 目標アーキテクチャ

DSLの中身（部品）をDatabricksに引き上げ、Difyは薄いUI層にする。

```
Databricks (共通部品・ガバナンス基盤)
┌──────────────────────────┐
│ モデル   → AI Gateway       │
│ ツール   → UC Functions     │
│ ナレッジ → Vector Search    │
└────────────┬─────────────┘
             │ API / MCP
       ┌─────┼─────┐
      DSL   DSL   DSL
     (軽量) (軽量) (軽量)
      ↑ UIとプロンプトだけ
```

### 管理対象の移行

| 管理対象 | 現状（Dify内） | 目標（Databricks） |
|---------|-------------|-----------------|
| LLMモデル | 各アプリに個別設定 | AI Gatewayで一元管理・コスト制御 |
| ツール | 各アプリに個別実装 | UC Functionsで共有・権限管理 |
| ナレッジ | 各アプリに個別ナレッジ | Vector Searchで一元管理 |
| DSLファイル | モデル+ツール+ナレッジ全部入り | UIとプロンプトだけの薄い層 |

### メッセージ

> DSLファイルを管理するのではなく、DSLの中身（部品）をDatabricksに引き上げるのが本質。
> アプリが乱立しても、部品はDatabricks側で統制できるので影響が最小化される。

---

## 2. Dify × Databricks 連携パターン（6種）

| # | パターン | 方向 | 難易度 | ガバナンス | 推奨場面 |
|---|---------|------|--------|----------|---------|
| ① | LLMモデル連携 | Dify→DB | ⭐ | ★★☆ | LLMモデルの一元管理・コスト管理 |
| ② | HTTP API連携 | Dify→DB | ⭐⭐ | ★★★ | UC関数・SQLクエリの直接実行 |
| ③ | MCP連携 | Dify→DB | ⭐ | ★★★ | 標準プロトコルでのツール連携 |
| ④ | RAG/Vector Search | Dify→DB | ⭐⭐ | ★★★ | ナレッジ管理の一元化 |
| ⑤ | Databricksオーケストレーター | DB→Dify | ⭐⭐ | ★★☆ | 大規模バッチAI処理 |
| ⑥ | 観測性/MLOps | 双方向 | ⭐⭐⭐ | ★★★ | 品質管理・モニタリング |

### 段階的導入ロードマップ

| Phase | 期間 | パターン | 目的 |
|-------|------|---------|------|
| Phase 1 | 1-2ヶ月 | ① LLM + ③ MCP | Quick Win: 最小限の変更でガバナンス効果を実感 |
| Phase 2 | 2-4ヶ月 | ② HTTP + ④ RAG | Deep Integration: ツール・ナレッジの一元化 |
| Phase 3 | 4-6ヶ月 | ⑤ オーケストレーター + ⑥ 観測性 | Full Governance: バッチ処理・品質管理の統合 |

---

## 3. Dify + Databricks LLM連携の技術的知見

### モデルファミリー別の互換性

DifyのOpenAI-API-compatibleプラグインは全リクエストに `user` パラメータを付与する。
Databricks FMAPI側の対応状況：

| モデルファミリー | `user`パラメータ | Difyとの相性 |
|-----------------|-----------------|-------------|
| GPT系 | 受け入れる | そのまま動く |
| Claude系 | 拒否する | パッチ必要 |
| Gemini系 | 拒否する | パッチ必要 |
| AI Gateway (カスタムルート) | 拒否する | パッチ必要 |

### Claude/Gemini系を使う場合のパッチ

プラグインの `models/llm/llm.py` の `_invoke` メソッド内、`super()._invoke()` 直前に追加：

```python
# Strip user param for Databricks compatibility
user = None
```

適用コマンド：
```bash
PLUGIN_DIR="/app/storage/cwd/langgenius/openai_api_compatible-0.0.40@.../models/llm/llm.py"
docker compose exec plugin_daemon sed -i \
  's/result = super()._invoke(/# Strip user param for Databricks compatibility\n        user = None\n        result = super()._invoke(/' \
  "$PLUGIN_DIR"
docker compose restart plugin_daemon
```

### Anthropicプラグインが使えない理由

Difyの公式AnthropicプラグインはカスタムAPI URL設定があるが、認証ヘッダーが `x-api-key` 固定。
Databricksは `Authorization: Bearer` を要求するため接続不可。

### ハンズオン推奨

- メイン: `databricks-gpt-5-2`（パッチ不要）
- 上級者向け: `databricks-claude-opus-4-6`（パッチ必要）

---

## 4. Day1コードAgentのDify連携方法

### Day1 Agentの構成

Day1で構築したLangGraphベースのエージェント：
- **エンドポイント**: `ricoh_technova_agent_yao_sl_st_catalog_ricoh_handson_code`（Model Serving）
- **内部構成**: ChatOpenAI + AI Gateway、UCFunctionToolkit、VectorSearchRetrieverTool
- **API形式**: MLflow ResponsesAgent（`input`/`output`形式、OpenAI Chat Completions形式ではない）

### DifyのLLMモデルとしては使えない

Difyの「OpenAI-API-compatible」プラグインはOpenAI Chat Completions形式を期待：
```
リクエスト: {"messages": [...]}  / レスポンス: {"choices": [...]}
```
Day1エンドポイントはMLflow形式：
```
リクエスト: {"input": [...]}  / レスポンス: {"output": [...]}
```
→ フォーマット不一致のため、モデルプロバイダーとしては接続不可。

### 連携方法の選択肢

| 方式 | 概要 | 推奨度 |
|------|------|--------|
| HTTP APIツール（Pattern ②） | DifyのWorkflow/ChatflowのHTTPリクエストノードで直接呼び出し | △ |
| ai_query() + UC Function + MCP（Pattern ③） | ai_queryでラップしてMCP公開 | ○ |
| 部品を直接MCP公開（UC Functions + Vector Search） | エンドポイントではなく部品を公開 | ◎ |

### ai_query()によるエレガントなラップ

`ai_query()` を使えばSQL1行でエンドポイントをUC Functionに変換できる：

```sql
CREATE OR REPLACE FUNCTION yao_sl_st_catalog.ricoh_handson_code.ask_agent(
  question STRING COMMENT 'ユーザーの質問'
)
RETURNS STRING
COMMENT 'Ricoh TechnoVaエージェントに質問する'
RETURN ai_query(
  'ricoh_technova_agent_yao_sl_st_catalog_ricoh_handson_code',
  question
);
```

Managed MCPで公開：
```
https://<workspace>/api/2.0/mcp/functions/yao_sl_st_catalog/ricoh_handson_code
```

#### ai_query() vs Python UC Function

| 観点 | Python UC Function | ai_query() |
|------|-------------------|------------|
| コード量 | ~10行（requests使用） | 1行 |
| 認証 | トークン管理が必要 | 自動 |
| エラーハンドリング | 自前実装 | 組込み |
| SQL内での利用 | 不可 | 可（SELECTで直接使える） |

#### ai_query()の制約

| 制約 | 内容 |
|------|------|
| タイムアウト | マルチステップ推論でSQL実行制限に引っかかる可能性 |
| ストリーミング不可 | 応答は全完了後に返却 |
| 会話履歴なし | ステートレス（マルチターン不可） |
| ResponsesAgent形式 | 新しい形式との互換性は要テスト |

### メッセージ

> エンドポイント丸ごとラップ（ai_query() → UC Function → MCP → Dify）は**技術的に可能**だが、
> Difyのオーケストレーション力を活かすなら、**部品（UC Functions + Vector Search）を直接MCP公開**して
> Dify側で組み立てる方がベスト。
>
> Day1（コードAgent）とDay2（ノーコードDify）は対立ではなく、
> **部品をDatabricksで共有し、UIを使い分ける**のが正しいアーキテクチャ。

---

## 5. DifyからHTTP APIで呼び出せるDatabricksサービス一覧

### 検証結果（全て実動確認済み）

| API | エンドポイント | 形式 | 認証 | Dify連携 |
|-----|-------------|------|------|----------|
| **UC Functions** | `POST /api/2.0/sql/statements/` | 同期REST | Bearer PAT | ◎ 最もシンプル |
| **Vector Search** | `POST /api/2.0/vector-search/indexes/{name}/query` | 同期REST | Bearer PAT | ◎ シンプル |
| **Genie** | `POST /api/2.0/genie/spaces/{id}/start-conversation` | 非同期REST（ポーリング必要） | Bearer PAT | △ ループ実装が必要 |
| **Knowledge Assistant (KA)** | `POST /serving-endpoints/ka-{id}-endpoint/invocations` | ResponsesAgent (`input`/`output`) | Bearer PAT | ○ 同期だが形式変換要 |
| **Supervisor Agent (MAS)** | `POST /serving-endpoints/mas-{id}-endpoint/invocations` | ResponsesAgent (`input`/`output`) | Bearer PAT | ○ 同期だが形式変換要 |
| **Code Agent (Day1)** | `POST /serving-endpoints/{name}/invocations` | ResponsesAgent (`input`/`output`) | Bearer PAT | ○ 同期だが形式変換要 |

### ResponsesAgent形式の注意点

KA/MAS/Code Agentは全て同じ**ResponsesAgent形式**：
```json
// リクエスト
{"input": [{"role": "user", "content": "質問"}]}

// レスポンス
{"output": [{"role": "assistant", "content": [{"type": "output_text", "text": "回答"}]}]}
```

DifyのOpenAI-API-compatibleプラグインが期待する形式（`messages`/`choices`）とは異なるため、
**LLMモデルとしては接続不可**。HTTPリクエストノードで呼び出し、レスポンスをJSONパースする。

### Genie APIの特殊性

Genieは非同期APIで3ステップ必要：
1. `POST start-conversation` → `conversation_id`, `message_id` を取得
2. `GET messages/{msg_id}` をポーリング（3秒間隔、statusが`COMPLETED`になるまで）
3. `attachments[].text` から回答、`attachments[].query.query` から生成SQLを取得

制約：5リクエスト/分/ワークスペース（POSTのみカウント、GETポーリングはカウント外）

### メッセージ

> Databricksの主要サービスは**全てREST APIで外部公開**されており、DifyのHTTPリクエストノードから呼び出せる。
> UC Functions / Vector Searchは同期APIでそのまま使える。
> KA / MAS / Code Agentも呼べるが、ResponsesAgent形式のためDifyのLLMプロバイダーではなくHTTPツールとして利用する。

---

## 6. Dify × Databricks 認証・権限管理

### パターン別の認証構造

| パターン | 必要なもの | 権限チェック |
|---------|----------|------------|
| SQL API（UC関数） | PAT + warehouse_id | Warehouse CAN USE + UC EXECUTE FUNCTION |
| Vector Search | PAT | UC SELECT on index |
| Genie | PAT + space_id | Space CAN VIEW |
| KA/MAS/Agent | PAT | Endpoint CAN QUERY（内部はSPの権限で実行） |
| MCP | PAT（headers内） | UC権限がMCP経由でも維持 |

### Dify運用時の問題: 全ユーザーが同じ権限

```
User A ─┐                   固定PAT（SP）
User B ─┼─▶ Dify App ──────────────▶ Databricks
User C ─┘   全員が同じ権限         UC権限で制御
```

Difyアプリには固定のPATが埋め込まれるため、ユーザー単位のアクセス制御は不可。

### ユーザー別アクセス制御が必要な場合

| 方式 | セキュリティ | コスト | 推奨場面 |
|------|-----------|--------|---------|
| Dify App × SP分離 | ○ ロール単位 | 低 | 部門別にデータを分けたい |
| Dify API + inputs経由でPAT渡し | △ PATがDifyを通過 | 中 | 技術的には可能だが複雑 |
| **Databricks Apps（OAuth U2M）** | ◎ ユーザー単位 | 中 | 厳格な制御が必要 |

### MCP設定におけるPATの扱い

MCP SSEプラグインの`headers`にPATが平文で埋め込まれる：
- Dify DB上は**PKCS1_OAEP暗号化**で保存される
- ただしDify管理者は設定画面から閲覧可能
- OAuth M2Mの動的トークン取得には未対応（プラグインの制約）

### PAT vs OAuth M2M

| 観点 | PAT | OAuth M2M |
|------|-----|-----------|
| トークン寿命 | 長期（手動管理） | 短期（自動ローテーション） |
| 漏洩リスク | 高（漏れたら即悪用） | 低（1時間で失効） |
| Difyでの利用 | ◎ Bearer埋めるだけ | △ トークン取得の仕組みが必要 |

### ベストプラクティス

1. **専用サービスプリンシパル（SP）を作成**（個人PATは使わない）
2. SPに**必要最小限のUC権限のみGRANT**
3. Dify専用の**小型warehouseを割り当て**（コスト分離）
4. Dify管理者を限定（PAT閲覧者の制限）

### メッセージ

> Difyの認証はPAT埋め込み方式で、ユーザー単位の制御はできない。
> これはDifyの制約であり、Databricks側の問題ではない。
> 本番運用では**専用SP + 最小権限GRANT**で影響を限定し、
> ユーザー単位の厳格な制御が必要なら**Databricks Apps（OAuth U2M）** を選択する。
>
> アプリが乱立しても、**データアクセスの権限はDatabricks側で統制**できることが最大のメリット。

---

## 7. Dify × Databricks MLflow 観測性連携

### Databricksネイティブプロバイダー（Dify v1.10.1〜）

Dify v1.10.1で追加されたDatabricks専用トレーシングプロバイダー。
PR [#26093](https://github.com/langgenius/dify/pull/26093)（2025年11月マージ）で、MLflowプロバイダーと同時に追加。

| 連携案 | 仕組み | 推奨度 |
|-------|--------|--------|
| **Databricksネイティブ** | Dify組み込みプロバイダーで直接送信 | **◎ 推奨** |
| MLflowプロバイダー | OSS MLflowサーバー経由 | ○ |
| Langfuse経由 | Dify→Langfuse→ETL→Databricks | △ |

### Experiment IDはDifyワークスペース共有

DatabricksプロバイダーのExperiment ID設定は**Difyワークスペース全体で1つ**。
アプリごとに異なるExperimentに送ることはできない。

```
Difyワークスペース
  ├── Agent App       ─┐
  ├── Workflow App     ─┤──▶ 1つのMLflow Experiment
  ├── Chatbot App      ─┘
```

**アプリの識別**: 現時点（Dify v1.13.0）では**トレースにアプリ名が含まれない**。
`tags['mlflow.traceName']`（スパン名）で種類を識別する:
- `message` → Agent/ChatbotのLLM呼び出し
- `mcp_sse_call_tool` → MCPツール呼び出し
- `workflow` → Workflowアプリのルートスパン
- `generate_conversation_name` → 会話タイトル生成（評価対象外）

### AI Judge自動評価（3段階）

| 評価 | 対象 | Scorer | 内容 |
|------|------|--------|------|
| A | LLM最終回答 | Safety, Guidelines | 安全性、日本語品質、事実性 |
| B | 検索結果+回答 | Guidelines（カスタム） | 回答が検索コンテキストに基づいているか |
| C | 全スパン | パフォーマンス分析 | レイテンシ、ボトルネック検出 |

トレースからの抽出ロジック:
- LLMトレース: `request`がmessages配列 → `role: user`のメッセージのみ抽出（system prompt除外）
- 検索トレース: `request.tool_name`に`knowledge_base`を含む → Vector Search結果
- ツールトレース: その他の`tool_name`

### メッセージ

> Difyでアプリが乱立しても、**観測性はDatabricks MLflowで一元管理**できる。
> Dify組み込みのDatabricksプロバイダーで追加インフラ不要。
> AI Judgeで品質を自動評価し、ガバナンスと品質の両立が可能。
> これはDify単体では実現できない、Databricks連携の大きな価値。

### スパンタイプとapp_nameの制約

MLflow/Databricksプロバイダーは同一の`MLflowDataTrace`を使用。トレース内容はアプリ構成により異なる:

| 構成 | RETRIEVERスパン | app_name | RetrievalGroundedness |
|------|---------------|----------|---------------------|
| Dify標準ナレッジのChatbot | ✅ | ❌ | ✅（理論上） |
| Workflowのナレッジ検索ノード | ✅ | ✅ | ✅（理論上） |
| MCP経由のVector Search | ❌（TOOLになる） | ❌ | ❌ |

- `app_name`はWorkflowの子スパンのattributesにのみ含まれる
- Agent/Chatbotのトレースには`app_name`が含まれない
- MCP経由のVector SearchはDifyの`RETRIEVER`スパンを通らないため`TOOL`タイプになる

### Dify v1.13.0 トレーシングバグ

External Knowledge（外部ナレッジ）を使うChatbotでトレースが送信されない:

```
ops_trace_manager.py:797 dataset_retrieval_trace
  start_time=timer.get("start")
  AttributeError: 'NoneType' object has no attribute 'get'
```

`dataset_retrieval_trace`でタイマー情報が`None`になり、全トレース処理がクラッシュする。
MCP Agent構成では`dataset_retrieval`を通らないため影響なし。
→ Dify側のバグ。修正されるまでExternal Knowledge + トレーシング併用は不可。
