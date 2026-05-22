# SOCKS5 Proxy Installer

基于 [microsocks](https://github.com/rofl0r/microsocks) 的一键 SOCKS5 代理部署脚本。

## 功能

- 自动安装编译依赖并编译 microsocks
- 随机生成端口、用户名和密码
- 配置 systemd 服务，开机自启
- 自动配置 iptables / ufw 防火墙规则
- 部署完成后输出连接信息并保存到本地文件

## 快速安装

```bash
curl -fsSL https://raw.githubusercontent.com/wareash/socks5-proxy-installer/main/install-socks5-proxy.sh | sudo bash
```

或直接下载后运行：

```bash
sudo bash install-socks5-proxy.sh
```

## 要求

- Debian / Ubuntu 系统
- root 权限
- 云服务器需在安全组中放行脚本生成的 TCP 端口

## 服务管理

```bash
sudo systemctl status microsocks
sudo systemctl restart microsocks
sudo systemctl stop microsocks
```

## 查看连接信息

部署完成后，连接信息保存在 `~/socks5-proxy-info.txt`，也可查看凭据文件：

```bash
cat ~/socks5-proxy-info.txt
sudo cat /etc/microsocks/credentials.env
```

输出示例：

```
服务器: 203.0.113.10
端口:   38921
用户名: a1b2c3d4e5f6g7h8
密码:   x9y8z7w6v5u4t3s2r1q0p9o8

连接 URL:
socks5://a1b2c3d4e5f6g7h8:x9y8z7w6v5u4t3s2r1q0p9o8@203.0.113.10:38921
```

---

## 配合 Sub2API 使用

本脚本可与 [Sub2API](https://github.com/Wei-Shaw/sub2api) 的 **IP 管理** 功能配合，实现「一号一 IP」：Sub2API 网关部署在一台服务器，上游 AI 请求通过独立 VPS 上的 SOCKS5 代理出站，避免多账号共用同一出口 IP。

```
客户端 → Sub2API 网关 → SOCKS5 代理（本脚本部署）→ OpenAI / Anthropic / Gemini
```

> **注意**：Sub2API 的 IP 管理是**按账号绑定代理**，不是系统级 `HTTP_PROXY`。给某个上游账号选了代理后，该账号的请求才会从对应 IP 出去。

### 第一步：在代理服务器部署 SOCKS5

找一台与 Sub2API **不同地区 / 不同 IP** 的 VPS（例如美国节点），执行快速安装命令。

部署完成后记录输出的 **连接 URL**（`socks5://用户名:密码@IP:端口`）。

**必做**：在云厂商安全组中放行脚本生成的 **TCP 端口**（脚本会尝试配置 iptables/ufw，但安全组必须手动放行）。

验证代理可用（在任意能访问该 IP 的机器上）：

```bash
curl -x "socks5://用户名:密码@服务器IP:端口" https://httpbin.org/ip
```

返回的 IP 应是代理服务器公网 IP。

### 第二步：进入 Sub2API IP 管理

1. 登录 Sub2API 管理后台（默认 `http://你的Sub2API地址:8080`）
2. 左侧菜单进入 **IP 管理**（路由 `/admin/proxies`）

Sub2API 支持的协议：`http`、`https`、`socks5`、`socks5h`。

### 第三步：导入代理

#### 方式 A：批量添加（推荐）

1. 点击 **添加代理** → 切换到 **批量添加**
2. 每行粘贴一条代理 URL：

```
socks5://用户名:密码@服务器IP:端口
```

3. 确认解析结果后，点击 **导入**

多台 VPS 各跑一遍脚本时，把每台的 URL 各占一行粘贴即可。

#### 方式 B：标准添加（单条）

| 字段 | 示例 |
|------|------|
| 名称 | `us-proxy-01` |
| 协议 | `socks5` |
| 主机 | `203.0.113.10` |
| 端口 | `38921` |
| 用户名 | `a1b2c3d4e5f6g7h8` |
| 密码 | `x9y8z7w6v5u4t3s2r1q0p9o8` |

#### 方式 C：JSON 导入（适合迁移）

点击 **导入**，上传 JSON 文件：

```json
{
  "exported_at": "2026-05-22T00:00:00Z",
  "proxies": [
    {
      "name": "us-proxy-01",
      "protocol": "socks5",
      "host": "203.0.113.10",
      "port": 38921,
      "username": "a1b2c3d4e5f6g7h8",
      "password": "x9y8z7w6v5u4t3s2r1q0p9o8",
      "status": "active"
    }
  ],
  "accounts": []
}
```

### 第四步：测试代理

在 IP 管理列表中对刚添加的代理：

1. 点击 **测试连接** — 检查延迟、出口 IP、地理位置
2. （可选）点击 **质量检测** — 检测对 OpenAI / Anthropic / Gemini 的连通性

| 现象 | 可能原因 |
|------|----------|
| 连接超时 | 云安全组未放行 TCP 端口 |
| 认证失败 | 用户名/密码与凭据文件不一致 |
| 测试通过但账号仍失败 | 账号未绑定该代理 |

### 第五步：绑定到上游账号

1. 进入 **账号管理**（`/admin/accounts`）
2. 新建或编辑上游账号
3. 在 **代理 IP** 下拉框中选择刚导入的代理（选「无代理」表示直连 Sub2API 服务器 IP）
4. 保存

绑定后，该账号所有上游请求的出口 IP = 代理服务器 IP。

#### 一号一 IP 建议

| 场景 | 做法 |
|------|------|
| 1 个 Claude 账号 | 1 台 VPS + 1 条代理 + 1 个 Sub2API 账号绑定 |
| 多个账号 | 每台 VPS 各部署脚本，各导入一条，分别绑定 |
| 同一代理多账号 | 技术上可行，但出口 IP 相同，关联风控风险更高 |

### 完整示例

```bash
# === 在美国 VPS 上 ===
curl -fsSL https://raw.githubusercontent.com/wareash/socks5-proxy-installer/main/install-socks5-proxy.sh | sudo bash
# 记下输出的 socks5://... URL，并在云安全组放行对应 TCP 端口

# === Sub2API 管理后台 ===
# IP 管理 → 添加代理 → 批量添加 → 粘贴 URL → 导入
# IP 管理 → 测试连接（确认出口 IP 正确）
# 账号管理 → 编辑账号 → 代理 IP 选该代理 → 保存
```

### 常见问题

**Sub2API 部署在阿里云，加了美国代理，请求来源 IP 是哪个？**

账号绑定代理后，来源 IP 是**代理服务器 IP**，不是 Sub2API 所在机器 IP。

**用 `socks5` 还是 `socks5h`？**

粘贴 `socks5://...` 即可；Sub2API 内部会将 `socks5` 升级为 `socks5h`，DNS 也走代理，避免 DNS 泄漏。

**重新运行安装脚本会怎样？**

会重新生成端口、用户名、密码。需要在 Sub2API 里更新或重新导入，并重新绑定账号。

**Sub2API 和代理可以同一台机器吗？**

可以，但出口 IP 仍是该机器 IP，无法做 IP 隔离；一般建议分开部署。

---

## 许可证

MIT
