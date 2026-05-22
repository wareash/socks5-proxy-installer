# SOCKS5 Proxy Installer

基于 [microsocks](https://github.com/rofl0r/microsocks) 的一键 SOCKS5 代理部署脚本。

## 功能

- 自动安装编译依赖并编译 microsocks
- 随机生成端口、用户名和密码
- 配置 systemd 服务，开机自启
- 自动配置 iptables / ufw 防火墙规则
- 部署完成后输出连接信息并保存到本地文件

## 使用方法

```bash
curl -fsSL https://raw.githubusercontent.com/<你的用户名>/socks5-proxy-installer/main/install-socks5-proxy.sh | sudo bash
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

## 许可证

MIT
