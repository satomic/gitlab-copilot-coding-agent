# 构建镜像
docker build -t satomic/gitlab-copilot-coding-agent-hook .

# 运行容器
docker run -itd \
  --name gitlab-copilot-coding-agent-hook \
  -p 8080:8080 \
  --env-file .env \
  --restart unless-stopped \
  satomic/gitlab-copilot-coding-agent-hook