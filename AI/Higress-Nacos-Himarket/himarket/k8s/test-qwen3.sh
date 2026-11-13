#!/bin/bash
# =============================================================================
# Qwen3-32B · 裸 Deployment 验证脚本
#
# 用法（在能执行 kubectl 的机器上跑，比如 <MODEL_CLUSTER_NODE>）：
#   bash test-qwen3.sh
#
# 四步依次验证：模型名 -> 普通对话 -> tool calling -> 多轮回传
# 全部通过才说明这个模型可以挂到 HiMarket / HiChat 的 Agent 场景。
# =============================================================================
set -u

NS=${NS:-kthena-system}
MODEL=${MODEL:-qwen3-32b}
SVC=${SVC:-vllm-qwen3-32b}

# ---- 拿访问地址：优先 Service ClusterIP，取不到退化成 Pod IP ----------------
IP=$(kubectl -n "$NS" get svc "$SVC" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
[ -z "$IP" ] || [ "$IP" = "None" ] && \
  IP=$(kubectl -n "$NS" get pod -l app="$SVC" -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)

if [ -z "$IP" ]; then
  echo "!! 拿不到 IP，先确认 Pod 是否 Ready:"
  kubectl -n "$NS" get pod -l app="$SVC" -o wide
  exit 1
fi

BASE="http://$IP:8000"
echo "== 目标: $BASE   模型名: $MODEL"
echo

# ---- 0. 健康与模型名 -------------------------------------------------------
echo "---- [0] /v1/models  期望看到 id = $MODEL"
curl -s -m 10 "$BASE/v1/models"; echo; echo

# ---- 1. 普通对话（关掉思考链，响应快） -------------------------------------
echo "---- [1] 普通对话  期望 200 + assistant content 非空"
curl -s -m 60 "$BASE/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "{
    \"model\": \"$MODEL\",
    \"messages\": [{\"role\": \"user\", \"content\": \"你好，用一句话介绍你自己\"}],
    \"max_tokens\": 64,
    \"chat_template_kwargs\": {\"enable_thinking\": false}
  }"; echo; echo

# ---- 2. tool calling（分水岭） ---------------------------------------------
echo "---- [2] 带 tools  期望 200 + choices[0].message.tool_calls 非空"
curl -s -m 120 "$BASE/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "{
    \"model\": \"$MODEL\",
    \"messages\": [{\"role\": \"user\", \"content\": \"北京今天天气怎么样？\"}],
    \"tools\": [{
      \"type\": \"function\",
      \"function\": {
        \"name\": \"get_weather\",
        \"description\": \"查询指定城市的实时天气\",
        \"parameters\": {
          \"type\": \"object\",
          \"properties\": {\"city\": {\"type\": \"string\", \"description\": \"城市名，如 北京\"}},
          \"required\": [\"city\"]
        }
      }
    }],
    \"tool_choice\": \"auto\",
    \"max_tokens\": 256,
    \"chat_template_kwargs\": {\"enable_thinking\": false}
  }"; echo; echo

# ---- 3. 流式 + tools（HiChat 走的就是 SSE） --------------------------------
echo "---- [3] 流式 tools  期望若干 data: 帧，含 tool_calls 增量"
curl -sN -m 120 "$BASE/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "{
    \"model\": \"$MODEL\",
    \"stream\": true,
    \"messages\": [{\"role\": \"user\", \"content\": \"上海天气如何？\"}],
    \"tools\": [{
      \"type\": \"function\",
      \"function\": {
        \"name\": \"get_weather\",
        \"description\": \"查询指定城市的实时天气\",
        \"parameters\": {\"type\": \"object\", \"properties\": {\"city\": {\"type\": \"string\"}}, \"required\": [\"city\"]}
      }
    }],
    \"max_tokens\": 256,
    \"chat_template_kwargs\": {\"enable_thinking\": false}
  }" | head -20; echo

# ---- 4. 回传工具结果续答（多轮 Agent 闭环） --------------------------------
echo "---- [4] 回传 role=tool  期望 200 + content 里出现「晴」或类似结论"
curl -s -m 120 "$BASE/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "{
    \"model\": \"$MODEL\",
    \"messages\": [
      {\"role\": \"user\", \"content\": \"北京今天天气怎么样？\"},
      {\"role\": \"assistant\", \"content\": null, \"tool_calls\": [{
        \"id\": \"call_1\", \"type\": \"function\",
        \"function\": {\"name\": \"get_weather\", \"arguments\": \"{\\\"city\\\": \\\"北京\\\"}\"}
      }]},
      {\"role\": \"tool\", \"tool_call_id\": \"call_1\", \"content\": \"{\\\"city\\\":\\\"北京\\\",\\\"weather\\\":\\\"晴\\\",\\\"temp\\\":\\\"18C\\\"}\"}
    ],
    \"max_tokens\": 128,
    \"chat_template_kwargs\": {\"enable_thinking\": false}
  }"; echo

echo "---- 完成。第 [2] 步返回里有 tool_calls 才算真正可用。"
