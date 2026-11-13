# ---------------------------------------------------------------------------
# 生产镜像：把「代码」和「运行环境」固化成不可变制品
#
# 为什么要自己打镜像，而不是继续用 kubeflow/python:3.7 + ConfigMap 挂脚本：
#   1. 不可复现  —— 上游 tag 可能被覆盖，今天跑的和明天跑的不是同一份东西
#   2. 无版本    —— ConfigMap 改了没有历史，出问题回不到上一版
#   3. 有大小限制 —— ConfigMap 单条上限 1MiB，代码稍大就挂不下
#   4. 权限过宽  —— kubeflow 镜像默认 root 运行，且带一堆用不到的工具
#   5. 无法扫描  —— 安全团队扫不了 ConfigMap 里的代码
#
# 构建（在 mini-mcp 目录下执行，因为要 COPY 同目录的 py 文件）：
#   docker build -f ../prod-mcp/Dockerfile -t mini-mcp:1.2.0 .
# 或者把 Dockerfile 拷到 mini-mcp 目录再构建。
#
# 离线环境：先用能上网的机器 docker save，再 docker load 进内网
#   docker save mini-mcp:1.2.0 | gzip > mini-mcp-1.2.0.tar.gz
#   docker load -i mini-mcp-1.2.0.tar.gz
# ---------------------------------------------------------------------------

# BASE_IMAGE 用 ARG 而不是写死：内网 Harbor 里不一定有官方 python 镜像，
# 构建时用 --build-arg BASE_IMAGE=harbor.ai.cnpc/ai-platform-poc/python:3.11-slim 覆盖即可。
ARG BASE_IMAGE=python:3.11-slim
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.title="mini-mcp" \
      org.opencontainers.image.description="Zero-dependency MCP server (Streamable HTTP + SSE)" \
      org.opencontainers.image.version="1.2.0"

# 非 root 用户。UID 固定 10001，方便在 Pod securityContext 里对齐。
RUN groupadd -g 10001 app \
 && useradd -u 10001 -g app -M -s /sbin/nologin app

WORKDIR /app

# 先拷代码再改属主，避免多一层
COPY --chown=10001:10001 mini_mcp_py2.py /app/mini_mcp_py2.py

# 预编译字节码：容器是只读根文件系统，运行时不能再写 __pycache__
RUN python3 -m py_compile /app/mini_mcp_py2.py \
 && chown -R 10001:10001 /app

USER 10001:10001

# 两个环境变量都有用：
#   PYTHONUNBUFFERED  → 日志实时进 kubectl logs，不加会攒到缓冲区满才输出
#   PYTHONDONTWRITEBYTECODE → 只读根文件系统下不尝试写 .pyc，避免告警
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    MCP_PORT=8765

EXPOSE 8765

# 容器级健康检查（k8s 用探针替代，但 docker run 场景仍有用）
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD python3 -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8765/healthz',timeout=2).status==200 else 1)"

ENTRYPOINT ["python3", "/app/mini_mcp_py2.py"]
CMD ["8765"]
