# onebox

## 免责声明

本项目仅供学习与技术研究，请在获得授权的服务器和网络环境中使用。使用者应遵守所在地适用的法律法规，不得用于违法或未经授权的活动，并自行评估和承担使用产生的风险。本项目按 [LICENSE](LICENSE) 原样提供，不提供任何明示或默示担保；作者及贡献者在适用法律允许的范围内不对使用本项目造成的损失承担责任。

以 root 运行。指定命令后自动进入无交互模式，也可附加 `--non-interactive`（`-n`）。安装脚本会自动安装 Bash 和执行安装操作所需的依赖。`status`、`doctor`、`logs` 为只读查看，缺少所需工具时会提示，不会安装依赖。

支持使用 apt、apk、dnf/yum、zypper、pacman 的 Debian/Ubuntu、Alpine、RHEL/Rocky/AlmaLinux/Fedora、openSUSE、Arch 等常见 Linux。需要**正在运行的 systemd 或 OpenRC**；无 init 的 Docker/WSL、其他 init、未知包管理器或架构会报错退出。支持 x86_64、ARM64、x86、ARMv6/v7、riscv64、s390x、ppc64le；具体版本必须提供对应官方发行包，Argo 仅支持前五类架构。Alpine 优先使用官方 musl 包。

## 交互式一键安装（推荐）

请用 root 登录。直接把 GitHub Raw 脚本交给 `sh` 执行：

```sh
wget -qO- "https://raw.githubusercontent.com/liuarui/onebox/main/install.sh" | sh -s -- menu
```

也可以使用 curl：

```sh
curl -fsSL "https://raw.githubusercontent.com/liuarui/onebox/main/install.sh" | sh -s -- menu
```

管道启动时，脚本会先通过同一个下载器获取一份可重启的临时副本，再自动安装缺失的 Bash；进入交互菜单时会从终端读取输入。执行安装操作时，其他缺失依赖也会自动安装。安装完成后直接执行 `onebox` 可再次打开管理菜单；无交互卸载使用 `onebox uninstall --yes`。

远程命令开始前必须已有能通过 HTTPS 证书校验访问 GitHub Raw 的 `wget` 或 `curl`；脚本尚未下载时无法替自己安装下载器。进入脚本后，缺少 Bash 和其他依赖会自动安装。

脚本地址：[GitHub Raw install.sh](https://raw.githubusercontent.com/liuarui/onebox/main/install.sh)。

## 已下载脚本的安装方式

```sh
# 打开交互安装菜单
sh install.sh menu
```

## 无交互安装

适合自动化部署。默认 VLESS + Reality、TCP 443，自动生成 UUID、Reality 密钥和分享链接；自动检测 SNI 并选择排名第一的候选，检测失败时使用第一个预设：

无交互一键安装：

```sh
wget -qO- "https://raw.githubusercontent.com/liuarui/onebox/main/install.sh" | sh -s -- add --protocol reality --port 443 --non-interactive
```

443 已占用或已有同名节点时会报错退出。为兼容已有用法，省略所有参数运行 `install.sh` 仍执行上述默认无交互安装；交互安装请保留 `menu`。

```sh
# 下载后显式无交互创建节点
sh install.sh add --protocol reality --port 443 --non-interactive

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

### Reality SNI 选择与自动检测

交互式添加或修改 `VLESS-REALITY` 的 SNI 时，先进入自动优选流程。只有资源不足、缺少检测能力、网络检测失败等情况，才显示以下 5 个预设供编号选择，无需手输域名；回车选第 1 项，`0` 取消。回退选择只使用 Bash 内建命令，不测速、不创建检测进程，适合低配置机器。

| 编号 | 预设 SNI |
| --- | --- |
| 1 | `www.intel.com` |
| 2 | `www.nvidia.com` |
| 3 | `www.ibm.com` |
| 4 | `www.sony.com` |
| 5 | `www.python.org` |

自动优选支持快速检测、全部候选、分类多选、地区推荐或自定义域名/网址列表，也可调整次数、超时和并发。检测成功时从通过的结果中选择；检测范围或结果菜单的 `0` 取消本次操作，不会触发预设回退。预设不代表已通过本机测速或 Reality 连接验证，选择后仍需确认实际连接。

内置 **83 个候选、9 类分类、9 个地区**。域名、分类和地区集中维护在 `install.sh` 的 `reality_sni_catalog()`，运行时无需下载或执行外部检测脚本。内置列表、自定义列表和显式指定的 Reality SNI 均排除 `apple.com`、`icloud.com`、`mzstatic.com` 及其子域名。

| 分类键 | 分类 | 数量 |
| --- | --- | --- |
| `cdn` | 全球 CDN / anycast | 2 |
| `cloud` | 云 / 开发基础设施 | 8 |
| `tech` | 科技 / 半导体大厂 | 14 |
| `fin` | 金融 / 支付 / 银行 | 9 |
| `edu` | 大学 / 教育机构 | 20 |
| `media` | 流媒体 / 内容 | 1 |
| `gaming` | 游戏平台 | 8 |
| `ecom` | 电商 / 零售 / 品牌 | 10 |
| `region` | 区域锚点 | 11 |

快速检测取 `cdn,cloud,tech`，共 24 个站点。地区键为 `global`（全球通用）、`us`（美国/北美）、`eu`（欧洲）、`jp`（日本）、`hk`（香港）、`sg`（东南亚/新加坡）、`cn`（中国大陆）、`au`（澳洲）、`kr`（韩国）。选择某地区会检测该区站点加全球通用站；`global` 只测全球通用站，`all` 不限制地区。地区标签按站点归属分类，韩国包括 Samsung、LG；标签不是站点 IP 地理定位，也不保证请求实际落在该地区。

每站使用 curl 检查 TLS 1.3、X25519、证书主机名/信任及实际 HTTP/2（h2）响应，不再启动 `openssl s_client`。HTTP 状态码为 403 等不影响 TLS 筛选。需要 curl ≥ 7.73、OpenSSL ≥ 1.1.1 TLS 后端和 HTTP2 支持；缺失依赖会自动安装，现有 curl 功能不足则提示并回退到预设，也可通过系统软件源升级 curl 或显式指定 `--sni`。curl ≥ 7.88 时统计服务端提供的证书链长度；旧版标为链长度未知，排在已知链之后。

默认并发上限 8、单次请求超时 5 秒、每站 3 次取最小值；界面显示完成进度。脚本按当前 cgroup v1/v2 及可见父级的剩余 PID、内存额度和系统可用内存自动下调并发，显式 `--sni-jobs` 也是上限。PID 通常保留 4 个任务额度；仅剩 4–6 个额度时可串行检测，少于 4 个时停止扫描。内存预算额外保留 16 MiB，每个检测任务估算 24 MiB；不足以启动一个任务时，交互模式回到预设编号选择，无交互模式使用第一个预设并提示未经本机测速。这些是扫描预算估算，实际内存用量还受 TLS 库和其他服务影响。

每个任务由父进程独立计时，超过“次数 × 单次超时 + 3 秒”后终止整组进程，避免 TLS 客户端卡住时整批一直等待。中断扫描会清理检测任务及临时文件。其他进程仍可能同时消耗额度，容器隐藏的宿主机限制也无法完全预判。

通过检查的短链站点（不超过 3 层）优先，同组按握手完成耗时排序；长链站点标为备选。耗时使用 `curl time_appconnect`，包含 DNS、TCP 和 TLS，不是纯 TLS 用时。自动推荐要求目标能返回 HTTP/2 响应，只有 TLS 握手成功而 HTTP 请求异常的站点不会入选。自动检测是 TLS 条件筛选，不能替代真实客户端的 Reality 连接验证；结果只代表服务器当前网络。

无交互模式省略 `--sni` 时自动检测 **全部 83 个候选**并选择排名第一的站点，不等待输入；检测失败或资源不足时自动使用第一个预设 `www.intel.com`，并提示未经本机测速。显式指定 `--sni DOMAIN` 可跳过自动检测；请将 `DOMAIN` 替换为你确认可用的域名。

```sh
# 日本地区站点＋全球通用站，自动选择第一名
onebox add --protocol reality --port 443 --sni-region jp

# 只测教育、科技分类；可与地区取交集
onebox add --protocol reality --port 443 --sni-category edu,tech --sni-region sg

# 用自定义列表替代内置候选，自动规范化网址、去重
onebox add --protocol reality --port 443 \
  --sni-hosts 'https://www.intel.com/ www.nus.edu.sg,www.amd.com' \
  --sni-jobs 4 --sni-samples 3 --sni-timeout 5
```

自动检测参数只适用于 `add --protocol reality`。`--sni-region` 默认 `all`，`--sni-category` 默认 `all`；两者可组合。`--sni-hosts` 支持 1–256 个域名或 HTTP(S) 网址，以空格或逗号分隔，替换内置列表，不与地区/分类筛选混用；仅探测 HTTPS 443。`--sni-jobs` 为并发上限，范围 `1–16`，`--sni-samples` 范围 `1–5`，`--sni-timeout` 范围 `1–15` 秒。显式 `--sni` 优先，跳过所有检测步骤。

## 添加节点

以下命令一次添加一个节点，完成后退出。`add` 也会自动安装内核、依赖和固定入口。已有同名节点或端口冲突时返回失败。

```sh
onebox add --protocol reality --tag reality-1 --port 443
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
| `--sni DOMAIN` | 指定 Reality 伪装域名并跳过自动检测；无交互省略时检测选第一名，失败使用第一个预设；新自签证书域名默认 `bing.com` |
| `--address HOST_OR_IP` | 分享链接中的服务器地址；省略则查询公网 IP，IPv6 不加方括号 |
| `--firewall auto\|skip` | 默认 `auto`，使用已有 ufw/firewalld/iptables 放行；`skip` 跳过 |
| `--version VERSION` | 内核未安装时选择的版本；已有内核用 `update` 更新 |

未指定密码时随机生成。密码文件建议 `chmod 600`；文件内容和环境变量不会作为 shell 代码执行。创建成功会输出节点凭据及链接，请妥善保存输出。自签证书需要客户端允许不验证证书。

Shadowsocks 支持 `aes-128-gcm`、`aes-256-gcm`、`chacha20-ietf-poly1305`、`2022-blake3-aes-128-gcm`、`2022-blake3-aes-256-gcm`、`2022-blake3-chacha20-poly1305`。2022 方法不指定密码时自动生成所需长度的 Base64 密钥。

自动放行仅处理本机已识别的防火墙，云安全组需要自行配置；裸 iptables 未配置持久化时，新增规则仅在当前运行期生效。firewalld 新规则会分别写入并核验永久与运行时状态，不会全局 reload；已有永久规则会补齐当前放行，已有临时规则则复用并提示自行持久化，卸载时保留这些已有规则。

新增规则会在变更前登记，部分放行失败时仍保留清理记录。iptables/ufw 查询异常或无法确认受管规则已消失时，清理返回失败并保留记录，处理后可重试。

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

同类节点共用一份真实/自签证书。已有证书与 `add` 指定的域名不匹配时会报错；应先确认已有节点的影响，再用 `cert` 更新共享证书。真实证书申请或复用时会安装并检查专属 cron 续期任务；该任务与管理操作共用锁，避免同时修改证书。更换域名后，旧域名中仍指向共享证书文件的续期记录会停用，失败时恢复原记录。续期数据保存在 onebox 专属目录。

## Argo

```sh
onebox add --protocol argo --tag argo-1 --port 18080 \
  --domain tunnel.example.com \
  --tunnel-token-file /root/tunnel-token
```

本模式使用 Cloudflare 后台管理的 Tunnel，需要**完整的连接器 Token**：从该隧道的安装连接器命令中复制 Token 本身。UUID 形式的 Tunnel ID、VLESS 用户 UUID、Cloudflare API Token 都不能替代它；只有 Tunnel ID 不足以认证。当前不支持本地管理隧道的 credentials JSON 模式。Token 文件为仅 root 可读的单行文件，也可使用 `SB_TUNNEL_TOKEN` 环境变量，勿公开分享。

在 Cloudflare Tunnel 后台为这条隧道添加 Published application/Public Hostname：

| 设置 | 本例的值 |
| --- | --- |
| 公共域名 | `tunnel.example.com`，必须与 `--domain` 一致 |
| Service 类型 | `HTTP` |
| Service URL | `127.0.0.1:18080`，完整地址为 `http://127.0.0.1:18080` |

本地入口仅监听 `127.0.0.1`，WebSocket 路径为 `/argo`。不要将目标填为 HTTPS、443 或其他端口；避免用 `localhost` 指向 IPv6 `::1`。Token 只用于连接已配置的隧道，脚本不会自动创建云端域名映射。使用 Cloudflare 后台创建映射时，还需确认对应 DNS 路由已生成，并允许 WebSocket，避免 Access 登录验证或挑战页拦截客户端。

客户端默认直接连接自己的隧道域名；确认正常后，可通过 `--edge HOST_OR_IP` 指定优选地址，Host/SNI 仍为隧道域名。服务 Token 单独以 `600` 权限保存。使用已有 cloudflared 时需支持 `--token-file`（2025.4.0+）。新建时会等待本机 `/ready` 确认连接到 Cloudflare；这不等于云端域名、origin 映射和客户端全部正常。

不通时先执行 `onebox doctor` 和 `onebox logs --tag argo-1`（systemd）：`1033` 优先检查连接器是否健康及 DNS 是否指向正确隧道；Tunnel 的 `502 / Unable to reach the origin service` 优先检查本机 sing-box、HTTP 协议和 `127.0.0.1:18080` 映射。Cloudflare 的说明见[运行参数](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/run-parameters/#token-file)与[故障排查](https://developers.cloudflare.com/tunnel/troubleshooting/)。

删除 Argo 节点时会备份隧道服务、受管 Token 及启用/运行状态；删除失败或中断时随节点配置一起恢复，恢复失败则保留事务备份并报错。

## Komari KNS 适配器

`onebox kns` schema 1 适配器版本为 `1.7.0`，支持历史节点只读发现、只读凭据导入、显式接管，以及 KNS 节点安装/状态/启停/重装/重配置/卸载和 Runtime 维护。`discover` 只返回 tag、协议、监听和可导入性，不返回凭据；`import` 只读取支持的旧节点并交给 KNS 加密保存，不修改 OneBox 配置。`claim` 会把一个受支持的旧入站迁移到 KNS 专属 tag 并写入受限权限的实例清单，保留原协议、端口、凭据和 TLS 配置；配置校验、共享服务重载或一次性 HTTPS 回调失败时会尝试回滚。接管后可通过 KNS 重配置、启停、重装和卸载该实例。接管和卸载都会重载共享 sing-box 服务，可能短暂影响同机其他节点；卸载只删除该 KNS 实例，不会停止或移除共享服务。只读 `status` 返回资源归属、共享引用计数和卸载预览。当前支持单用户 VLESS Reality、Hysteria2、TUIC、AnyTLS 和 Shadowsocks；VLESS WS/Argo、多用户节点和不完整配置会显示为暂不支持。停用或卸载仅在共享配置不再引用对应端口/协议时清理防火墙规则。回调包含协议凭据和 TLS 参数（包括 ALPN）。

小内存或低 PID 限额 LXC 会优先走串行路径：Reality 自动检测按可见 cgroup PID/内存余量降到单任务；旧节点发现批量读取端口元数据，避免每个 inbound 单独启动 jq；证书域名优先使用 OneBox secrets/配置，缺失时最多启动一个 openssl 进程读取证书 CN，不再启动多进程管道。检测到的剩余 PID 少于 3 时跳过 KNS 发现，导入少于 5 时跳过，安装/依赖变更少于 8 时跳过；可见可用内存低于 16/32/64 MiB 时，也会分别跳过发现/导入/安装和依赖变更，避免在余量不足时启动重操作。Linux cgroup 的 `pids.current` 统计内核 task，包含线程，因此 20–30 的总额度还要扣除容器 init、Komari Agent、sing-box 和其他进程/线程。剩余额度是启动前采样，不是预留；其他系统进程仍可能抢占，隐藏的宿主机限制也无法探测，因此预检不是硬资源保证。运行仍需要 Bash 4+、jq（导入还需 curl 与支持 `--close` 的 flock），并要求 systemd 或 OpenRC；在无 init 容器或依赖缺失且无法预装的环境中不保证可用。

```sh
onebox kns schema
onebox kns list
onebox kns discover
onebox kns status --instance-id vless-main
onebox kns runtime-status
onebox kns update-script --request-file /run/onebox/kns/requests/script-update.json
onebox kns update-kernel --request-file /run/onebox/kns/requests/kernel-update.json
onebox kns install --request-file /run/onebox/kns/requests/job-001.json
onebox kns import --request-file /run/onebox/kns/requests/import-001.json
onebox kns claim --request-file /run/onebox/kns/requests/claim-001.json
onebox kns reconfigure --request-file /run/onebox/kns/requests/job-002.json
onebox kns reinstall --request-file /run/onebox/kns/requests/job-003.json
onebox kns disable --request-file /run/onebox/kns/requests/job-004.json
onebox kns enable --request-file /run/onebox/kns/requests/job-005.json
onebox kns uninstall --request-file /run/onebox/kns/requests/job-006.json
```

节点变更与 Runtime 更新请求均使用 schema 1 JSON 文件。Runtime 更新请求的 `instance` 必须为 `null`，`update-script` 绑定 KNS 固定 SHA-256，`update-kernel` 只接受 `latest` 稳定版。请求目录只允许 root 写入；请求文件必须由 root 拥有、权限为 `0600` 或 `0400`、大小不超过 64 KiB，并在执行后删除。Komari 插件应通过安全文件传输下发请求，避免把节点凭据打印到 Agent 任务日志。

```sh
install -d -o root -g root -m 0700 /run/onebox/kns/requests
install -o root -g root -m 0600 /dev/null /run/onebox/kns/requests/job-001.json
```

```json
{
  "schema": 1,
  "jobId": "job-001",
  "machineUuid": "komari-uuid-001",
  "action": "install",
  "runtime": { "engine": "sing-box", "id": "onebox-main" },
  "instance": {
    "id": "vless-main",
    "protocol": "vless",
    "listenPort": 443,
    "transport": "tcp",
    "options": { "security": "reality", "sni": "www.example.com" }
  },
  "idempotencyKey": "komari-uuid-001:vless-main:install:v1",
  "report": {
    "callback": "https://monitor.example.com/api/kns/report",
    "oneTimeToken": "replace-with-at-least-32-random-characters"
  }
}
```

当前支持 VLESS + Reality（TCP）、Hysteria 2（UDP）、TUIC（UDP）、AnyTLS（TCP）、Trojan（TCP）、VMess（TCP）和 Shadowsocks（TCP + UDP）。VLESS 的 `options.security` 固定为 `reality`；需要 TLS 的其他协议须提供有效的 `options.sni`。Shadowsocks 可通过 `options.method` 指定加密方法。可选参数：`alpn`（1–8 个字符串）、`allowInsecure`（布尔）；VLESS 另支持 `flow`、`fingerprint`、`spiderX`；Hysteria2 另支持 `upMbps`、`downMbps`、`obfs`、`obfsPassword`；VMess 另支持 `alterId`、`cipher`；TUIC 另支持 `congestionControl`、`udpRelayMode`。

可选的 `instance.listenAddress` 仅支持 `::`、`0.0.0.0`、`127.0.0.1` 或 `::1`，默认 `::`。它控制本机监听接口；订阅发布使用的公网域名或地址由 Komari 插件另行配置。

节点结果通过 `report.callback` HTTPS POST 回传，使用 `Authorization: Bearer <oneTimeToken>` 和 JSON 内容类型。回调返回任意 HTTP 2xx 即视为已接收；服务端应校验 schema、`jobId`、`machineUuid` 和一次性 Token，并拒绝重放。回调正文遵循 KNS schema，包含运行时、实例监听参数、协议凭据及受管资源；命令行标准输出只返回脱敏状态。节点配置变更在回调成功后提交，回调失败会尝试恢复配置与服务状态。管理脚本更新使用固定产物摘要，更新或回调失败时尝试恢复脚本并保留原权限；内核更新会在结束事务前核验目标版本和原服务状态，安装核验失败时恢复旧内核及配置。若内核已经核验成功但 HTTPS 回调失败，机器会保留更新后的内核并输出真实 Runtime 状态；KNS 应显示需核查，不能把它当作普通安装失败或自动再次升级。

`instance` 不包含公网 Endpoint。Komari 插件应自行解析机器 IPv4/IPv6、域名、NAT 端口和 DDNS，并在发布订阅时选择连接地址。TLS 协议会复用匹配 SNI 的 OneBox 真实证书；找不到匹配证书时会为该实例生成独立自签证书，客户端结果会标记 `allowInsecure: true`。部署前应通过 `onebox cert --cert real ...` 配置与 SNI 匹配的真实证书，或让订阅端明确处理自签证书。

安装后会尝试通过 OneBox 已支持的本机防火墙工具放行相应 TCP/UDP 端口，卸载时仅清理 OneBox 登记且不再被其他节点使用的规则。云厂商安全组仍需单独设置；本机没有受支持的防火墙工具或规则操作失败时会输出提示，节点配置仍会保留。

相同实例与配置的重复 `install` 幂等；`reinstall` 从已保存的实例配置恢复并保留凭据，不能借此修改实例参数。配置变化应使用 `reconfigure`；同协议重配置会尽量复用现有凭据。`enable` 和 `disable` 只修改指定 KNS inbound，保留登记文件与凭据；`uninstall` 可删除启用或已停用实例，且需要携带相同机器 UUID 并通过一次性回调确认实例已移除。`list` 和 `status` 不显示凭据；状态等级只反映本机服务和监听情况，不等同于真实代理握手验证。

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

安装及更新会显示各阶段的开始、完成或失败状态；内核替换后会从固定安装路径验证能否运行，再报告安装完成。启动或重启后会等待最多 10 秒，确认主进程已监听配置所需的 TCP/UDP 端口。失败时会显示退出码、Bash 版本、系统架构及日志路径。

`update-script` 从本仓库的 `main` 分支下载。`install` 重复运行会保留现有节点；指定版本不会替换已安装内核，替换请使用 `update --version`。

`doctor` 汇总程序是否可运行、配置 JSON、主服务和登记隧道的状态，以及配置中引用的 onebox 证书有效期；7 天内到期会提醒。发现异常或缺少检查工具时返回 `1`，不会联网修复或安装依赖。内核完整配置校验仍使用 `onebox check`。`status` 会区分 `not-installed`、`inactive`/`stopped`、`failed`、`active` 等状态。

菜单打开时不联网检查新版本；安装或更新内核时才查询版本。“查看节点”子菜单直接打开，不会先安装依赖。生成需要公网 IP 的链接时，会显示查询提示并限制单次请求时间；查询失败仍可查看节点参数，也可执行 `onebox links --address 你的公网IP`。Argo 和使用真实证书域名的节点无需查询公网 IP。

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
