# onebox

## 免责声明

本项目仅供学习与技术研究，请在获得授权的服务器和网络环境中使用。使用者应遵守所在地适用的法律法规，不得用于违法或未经授权的活动，并自行评估和承担使用产生的风险。本项目按 [LICENSE](LICENSE) 原样提供，不提供任何明示或默示担保；作者及贡献者在适用法律允许的范围内不对使用本项目造成的损失承担责任。

以 root 运行。指定命令后自动进入无交互模式，也可附加 `--non-interactive`（`-n`）。安装等操作会通过系统包管理器安装缺失依赖；下载到文件后用 `sh install.sh` 执行，还可自动安装 Bash。`status`、`doctor`、`logs` 为只读查看，缺少所需工具时会提示，不会安装依赖。

支持使用 apt、apk、dnf/yum、zypper、pacman 的 Debian/Ubuntu、Alpine、RHEL/Rocky/AlmaLinux/Fedora、openSUSE、Arch 等常见 Linux。需要**正在运行的 systemd 或 OpenRC**；无 init 的 Docker/WSL、其他 init、未知包管理器或架构会报错退出。支持 x86_64、ARM64、x86、ARMv6/v7、riscv64、s390x、ppc64le；具体版本必须提供对应官方发行包，Argo 仅支持前五类架构。Alpine 优先使用官方 musl 包。

## 一键安装

请先用 root 登录，或执行 `sudo -i` 切换到 root：

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/liuarui/onebox/main/install.sh")
```

上面命令默认**无交互安装 VLESS + Reality，监听 TCP 443**，自动生成 UUID、Reality 密钥和分享链接，默认伪装域名 `apple.com`。443 已占用或已有同名节点时会报错退出，不会换成随机端口。等价的显式命令是：

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/liuarui/onebox/main/install.sh") add --protocol reality --port 443 --non-interactive
```

请在 Bash 终端执行，系统需先有 Bash、curl 和 CA 证书。精简 Alpine 可先执行 `apk add --no-cache bash curl ca-certificates`，再运行 `bash` 切换终端；Debian/Ubuntu 可先执行 `apt-get update && apt-get install -y bash curl ca-certificates`。其余依赖由脚本自动安装。

脚本会将流式入口重新下载到私有临时目录，校验后执行，正常退出或失败时清理临时文件。安装后执行 `onebox` 进入菜单，执行 `onebox uninstall --yes` 无交互卸载。

脚本地址：[GitHub Raw install.sh](https://raw.githubusercontent.com/liuarui/onebox/main/install.sh)。

## 已下载脚本的安装方式

```sh
# 默认无交互安装 VLESS + Reality，端口 443
sh install.sh

# 只安装管理脚本和内核，不添加节点
sh install.sh install --non-interactive

# 指定 sing-box 版本；不指定则安装最新稳定版
sh install.sh install --version 1.14.3
```

固定位置：

| 内容 | 路径 |
| --- | --- |
| 管理命令 | `/usr/local/bin/onebox` |
| sing-box / 受管 cloudflared | `/usr/local/lib/onebox/` |
| 节点配置、证书、密钥 | `/etc/onebox/` |
| 续期工具及管理记录 | `/var/lib/onebox/` |
| 失败日志 | `/var/log/onebox/` |

安装完成后使用 `onebox <命令>`。再次直接执行 `onebox` 可进入交互菜单，其中包含卸载选项。

## 添加节点

以下命令一次添加一个节点，完成后退出。`add` 也会自动安装内核、依赖和固定入口。已有同名节点或端口冲突时返回失败。

```sh
onebox add --protocol reality --tag reality-1 --port 443 --sni apple.com
onebox add --protocol hysteria2 --tag hy2-1 --port 8443 --cert self
onebox add --protocol tuic --tag tuic-1 --port 9443 --cert self
onebox add --protocol anytls --tag anytls-1 --port 10443 --cert self
onebox add --protocol shadowsocks --tag ss-1 --port 11443 --method aes-128-gcm
```

可选参数：

| 参数 | 用途 / 默认值 |
| --- | --- |
| `--tag NAME` | 节点名称，仅字母、数字、短横线、下划线；省略则按协议和主机名生成 |
| `--port PORT` | 监听端口；省略则随机选择空闲端口 |
| `--uuid UUID` | Reality、TUIC、Argo 的 UUID；省略则随机生成 |
| `--password-file PATH` | 从单行文件读取密码；也支持 `SB_PASSWORD` 环境变量和 `--password VALUE` |
| `--cert self\|real` | Hysteria2/TUIC/AnyTLS 使用的证书；默认 `self` |
| `--sni DOMAIN` | Reality 伪装域名默认 `apple.com`；新自签证书域名默认 `bing.com` |
| `--address HOST_OR_IP` | 分享链接中的服务器地址；省略则查询公网 IP，IPv6 不加方括号 |
| `--firewall auto\|skip` | 默认 `auto`，使用已有 ufw/firewalld/iptables 放行；`skip` 跳过 |
| `--version VERSION` | 内核未安装时选择的版本；已有内核用 `update` 更新 |

未指定密码时随机生成。密码文件建议 `chmod 600`；文件内容和环境变量不会作为 shell 代码执行。创建成功会输出节点凭据及链接，请妥善保存输出。自签证书需要客户端允许不验证证书。

Shadowsocks 支持 `aes-128-gcm`、`aes-256-gcm`、`chacha20-ietf-poly1305`、`2022-blake3-aes-128-gcm`、`2022-blake3-aes-256-gcm`、`2022-blake3-chacha20-poly1305`。2022 方法不指定密码时自动生成所需长度的 Base64 密钥。

自动放行仅处理本机已识别的防火墙，云安全组需要自行配置；裸 iptables 未配置持久化时，新增规则仅在当前运行期生效。firewalld 新规则会分别写入并核验永久与运行时状态，不会全局 reload；已有永久规则会补齐当前放行，已有临时规则则复用并提示自行持久化，卸载时保留这些已有规则。

## 证书

Cloudflare DNS 验证，API Token 需具备目标区域的 DNS 编辑权限及区域读取权限：

```sh
# /root/cf-token 是仅 root 可读的单行 Token 文件
onebox add --protocol hysteria2 --tag hy2-real --port 8443 \
  --cert real --domain node.example.com --cf-token-file /root/cf-token

# 单独申请或更新共享真实证书
onebox cert --cert real --domain node.example.com --cf-token-file /root/cf-token
```

也可通过 `CF_Token`，或 `CF_Key` + `CF_Email` 环境变量提供凭据；使用 sudo 时需自行传递所需变量。默认验证方式为 `dns`。

HTTP-01 验证要求域名解析正确、公网 80/TCP 长期可达且验证时端口空闲：

```sh
onebox cert --cert real --domain node.example.com --validation http --http01-ready
```

自签证书单独生成：

```sh
onebox cert --cert self --sni bing.com
```

同类节点共用一份真实/自签证书。已有证书与 `add` 指定的域名不匹配时会报错；应先确认已有节点的影响，再用 `cert` 更新共享证书。真实证书申请时会安装并启动 cron，续期数据保存在 onebox 专属目录。

## Argo

```sh
onebox add --protocol argo --tag argo-1 --port 18080 \
  --domain tunnel.example.com --edge saas.sin.fan \
  --tunnel-token-file /root/tunnel-token
```

Token 文件为仅 root 可读的单行文件，也可使用 `SB_TUNNEL_TOKEN` 环境变量。请在 Cloudflare Tunnel 后台将该域名的服务目标设为 `http://localhost:18080`。本地入口仅监听 `127.0.0.1`，服务 Token 单独以 `600` 权限保存。

## 查看、管理与更新

```sh
onebox list
onebox links
onebox links --tag reality-1 --address 203.0.113.10
onebox check
onebox status
onebox doctor
onebox logs                            # systemd 服务最近 80 行日志
onebox logs --lines 200
onebox logs --tag argo-1               # 已登记的 cloudflared 隧道
onebox logs --source install          # 最近安装步骤日志（执行中或失败保留）
onebox start
onebox stop
onebox restart
onebox delete --tag reality-1 --yes
onebox update
onebox update --version 1.14.3
onebox update-script
onebox outbound --strategy ipv4_only   # 也可 ipv6_only、auto
onebox bbr                            # 内核不支持或外部配置冲突时返回失败
onebox --help
```

`update-script` 从本仓库的 `main` 分支下载。`install` 重复运行会保留现有节点；指定版本不会替换已安装内核，替换请使用 `update --version`。

`doctor` 汇总程序是否可运行、配置 JSON、主服务和登记隧道的状态，以及配置中引用的 onebox 证书有效期；7 天内到期会提醒。发现异常或缺少检查工具时返回 `1`，不会联网修复或安装依赖。内核完整配置校验仍使用 `onebox check`。`status` 会区分 `not-installed`、`inactive`/`stopped`、`failed`、`active` 等状态。

`logs` 默认查看 systemd journal，`--lines` 范围为 `1–1000`。OpenRC 当前未配置服务运行日志落盘，查看运行日志会提示并返回 `3`；两种服务管理器都可用 `--source install` 查看最近安装步骤日志。成功步骤的日志会删除；安装进行时可能显示当前步骤，安装结束后保留的是失败步骤。日志可能包含网络地址等信息，分享前请检查内容。

## 卸载与清理

```sh
onebox uninstall --yes

# 管理命令损坏时，也可重新下载脚本后卸载
sh install.sh uninstall --yes
```

会停止并移除 onebox 及登记的隧道服务，清理受管防火墙规则、程序、配置、证书、专属 ACME 续期任务、缓存、日志及管理记录，默认恢复由本脚本登记的 BBR 设置。某一步清理失败会返回非零，并保留可重试的入口或恢复记录。

如需保留 BBR 参数和恢复记录：`onebox uninstall --yes --keep-bbr`。项目中的原始 `install.sh`、用户提供的 Token 文件、系统依赖包、系统日志和其他程序的资源不会删除；无法确认归属或已被外部修改的资源会保留并提示。

退出码：`0` 成功；`1` 操作失败或服务未运行；`2` 参数错误；`3` 环境不支持；`75` 其他 onebox 操作正在运行。安装后的 `onebox` 不带参数且无终端时立即报错；使用 `onebox -n` 或直接运行 `install.sh` 则按默认配置无交互安装，不会等待输入。
