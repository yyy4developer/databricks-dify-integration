from flask import Flask, request, jsonify
import requests as http_requests
import os

app = Flask(__name__)

DATABRICKS_HOST = os.environ.get("DATABRICKS_HOST")
DATABRICKS_TOKEN = os.environ.get("DATABRICKS_TOKEN")
VS_INDEX_NAME = os.environ.get("VS_INDEX_NAME")
API_KEY = os.environ.get("API_KEY", "dify-external-knowledge-key")


@app.route("/retrieval", methods=["POST"])
def retrieval():
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer ") or auth[7:] != API_KEY:
        return jsonify({"error_code": 1002, "error_msg": "Authorization failed"}), 403

    data = request.json
    query = data.get("query", "")
    settings = data.get("retrieval_setting", {})
    top_k = settings.get("top_k", 3)
    score_threshold = settings.get("score_threshold", 0.0)

    vs_url = f"https://{DATABRICKS_HOST}/api/2.0/vector-search/indexes/{VS_INDEX_NAME}/query"
    vs_resp = http_requests.post(vs_url, headers={
        "Authorization": f"Bearer {DATABRICKS_TOKEN}",
        "Content-Type": "application/json"
    }, json={
        "query_text": query,
        "columns": ["content", "doc_uri"],
        "num_results": top_k
    })

    vs_data = vs_resp.json()
    records = []
    for row in vs_data.get("result", {}).get("data_array", []):
        content, doc_uri, score = row[0], row[1], row[-1]
        if score >= score_threshold:
            records.append({
                "content": content,
                "score": score,
                "title": doc_uri,
                "metadata": {"source": doc_uri}
            })

    return jsonify({"records": records})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8089)
