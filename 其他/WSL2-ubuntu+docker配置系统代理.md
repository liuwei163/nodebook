# WSL2 Ubuntu26\.04 测试环境代理 \+ Docker 完整部署配置文档

## 一、环境基础信息

- **运行环境**：WSL2

- **系统版本**：Ubuntu 26\.04\.1 LTS \(resolute\)

- **测试代理地址**：`192.168.3.100:8080`

- **测试内网Harbor仓库**：`harbor.test.local`、`192.168.3.200`

- **核心需求**：APT软件安装代理、Docker镜像拉取代理、外网镜像加速、内网仓库豁免代理、普通用户免sudo操作Docker

## 二、APT全局代理\+强制IPv4配置（解决更新超时、IPv6报错）

### 2\.1 配置APT测试代理

创建APT永久代理配置，适配sudo权限，无需手动声明环境变量

```bash
cat <<EOF | sudo tee /etc/apt/apt.conf.d/99proxy
Acquire::http::Proxy "http://192.168.3.100:8080";
Acquire::https::Proxy "http://192.168.3.100:8080";
EOF
```

### 2\.2 强制APT仅使用IPv4

彻底解决系统优先IPv6导致的网络不可达、连接超时问题

```bash
echo 'Acquire::ForceIPv4 "true";' | sudo tee /etc/apt/apt.conf.d/99force-ipv4
```

### 2\.3 配置校验与更新源

```bash
# 校验代理配置生效
apt-config dump | grep -i proxy
# 校验强制IPv4生效
apt-config dump | grep ForceIPv4

# 更新软件源
sudo apt update
# 可选：升级系统全部软件包
# sudo apt upgrade -y
```

## 三、Docker Engine 完整安装流程

适配Ubuntu26\.04，兼容使用Ubuntu24\.04\(noble\)官方Docker源，完美兼容无版本报错

### 3\.1 安装依赖组件

```bash
sudo apt install ca-certificates curl gnupg lsb-release -y
```

### 3\.2 导入Docker官方密钥

```bash
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
```

### 3\.3 添加Docker官方APT源

```bash
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu noble stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
```

### 3\.4 安装Docker全套服务

```bash
sudo apt update
sudo apt install docker-ce docker-ce-cli containerd.io docker-compose-plugin -y
```

### 3\.5 启动Docker并设置开机自启

```bash
sudo systemctl start docker
sudo systemctl enable docker
```

## 四、Docker Daemon核心配置（代理\+加速\+内网仓库）

核心配置文件：`/etc/docker/daemon.json`，包含四大功能：外网代理、内网豁免、镜像加速、私有仓库证书豁免

```bash
sudo tee /etc/docker/daemon.json <<'EOF'
{
  "proxies": {
    "http-proxy": "http://192.168.3.100:8080",
    "https-proxy": "http://192.168.3.100:8080",
    "no-proxy": "localhost,127.0.0.1,::1,192.168.0.0/16,10.0.0.0/8,172.16.0.0/12,harbor.test.local,192.168.3.200"
  },
  "registry-mirrors": [
    "https://docker.1ms.run",
    "https://docker.1panel.live",
    "https://docker.m.daocloud.io"
  ],
  "insecure-registries": [
    "harbor.test.local",
    "192.168.3.200"
  ]
}
EOF
```

### 4\.1 重载配置并重启Docker

```bash
sudo systemctl daemon-reload
sudo systemctl restart docker
```

### 4\.2 配置校验

```bash
# 查看完整Docker配置（确认代理、加速、私有仓库全部生效）
sudo docker info

# 测试外网镜像拉取
sudo docker pull hello-world
```

**校验标准**：`docker info` 输出中包含 Proxy、Registry Mirrors、Insecure Registries 对应配置即为生效

## 五、普通用户免sudo操作Docker配置

解决 `permission denied while trying to connect to the docker API` 权限报错

### 5\.1 将当前用户加入Docker用户组

```bash
sudo usermod -aG docker $USER
```

### 5\.2 生效关键操作（必做）

修改用户组后，**必须关闭当前所有WSL终端，重新打开终端**，配置方可永久生效（newgrp命令需额外安装依赖，不推荐临时生效）。

### 5\.3 权限校验

```bash
# 查看用户所属组，包含docker即为成功
id

# 免sudo测试
docker images
docker ps
```

## 六、核心配置文件汇总

|配置文件路径|作用|
|---|---|
|`/etc/apt/apt.conf.d/99proxy`|APT软件安装全局代理|
|`/etc/apt/apt.conf.d/99force-ipv4`|强制APT仅使用IPv4，禁用IPv6|
|`/etc/docker/daemon.json`|Docker服务代理、镜像加速、私有仓库配置|
|`/etc/group`|用户组配置（存放docker权限用户）|

## 七、故障回滚方案

### 7\.1 重置Docker所有配置

```bash
sudo tee /etc/docker/daemon.json <<'EOF'
{}
EOF
sudo systemctl daemon-reload
sudo systemctl restart docker
```

### 7\.2 删除APT代理与IPv4限制

```bash
sudo rm -f /etc/apt/apt.conf.d/99proxy /etc/apt/apt.conf.d/99force-ipv4
```

### 7\.3 移除用户Docker权限

```bash
sudo deluser $USER docker
```

## 八、关键避坑注意事项

1. **三层代理区分（核心）**

    - APT代理：仅作用于 `apt install/update` 系统包安装

    - Docker daemon代理：仅作用于 `docker pull/build` 镜像操作

    - Shell环境变量代理：仅作用于当前终端 `curl/wget`，不影响APT和Docker

2. **no\-proxy规则**：仅配置内网私有地址/域名，外网镜像加速源**禁止加入**豁免列表，需走代理加速

3. **用户组生效规则**：usermod修改组后，必须重启WSL终端，临时newgrp生效不持久

4. **版本兼容说明**：Ubuntu26\.04无官方Docker源，使用24\.04\(noble\)源完全兼容，无兼容性报错

5. **私有仓库适配**：insecure\-registries配置用于放行内网Harbor自签名证书，避免镜像拉取证书报错

> （注：部分内容由豆包工作 AI 生成）
