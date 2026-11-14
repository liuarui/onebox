# Changelog

本文件记录 OneBox 的正式版本变更。

## [1.0.8] - 2026-11-14

- Rank selected-region candidates ahead of global fallback endpoints within the same certificate-chain tier.
- Keep global endpoints as lower-priority fallback candidates instead of competing with regional institutions by latency.
- Keep the 27-domain SNI catalog unchanged; no domains were added or restored.

## [1.0.7] - 2026-11-14

- Correct the affiliation-region labels for Waikato, NCKU, and NCU.
- Prioritize a selected region's institutional candidates within the same certificate-chain tier; keep global endpoints as lower-priority fallback.
- Add an explicit Taiwan region for NCKU and NCU instead of grouping Taiwan under Southeast Asia/Singapore.
- Keep the 27-domain catalog unchanged; no domains were added or restored.

## [1.0.6] - 2026-11-14

- Replace high-profile corporate SNI defaults with open-source, research-network, RIR/NIR, and regional university endpoints.
- Remove built-in candidates hosted by Cloudflare and prune finance, commerce, gaming, media, airline, automotive, and other high-association categories.
- Diversify fallback presets across Fastly, Bunny, and research or numbering-authority networks; every VPS still verifies TLS 1.3, X25519, certificate trust, and HTTP/2 at runtime.
- Document that DNS, CDN, and ASN observations are snapshots and are not permanent domain metadata.
- Clarify that less-associated domains reduce visible network overlap but cannot guarantee resistance to blocking or active probing; VPS IP reputation and traffic behavior still matter.
- Refresh the README with compact badges, navigation, a feature overview, and a deployment diagram.

## [1.0.5] - 2026-11-11

- Remove fixed RAM/swap preflight thresholds from maintenance, node, and dependency operations; report failures from the actual command.
- Keep PID headroom checks and RAM-based SNI concurrency adjustment.

## [1.0.4] - 2026-11-11

- Include available swap in maintenance preflight, constrained by visible cgroup v2 swap or cgroup v1 memory+swap limits.
- Lower ordinary OneBox node commands to a 32 MiB RAM+swap gate; keep 64 MiB for kernel upgrades and first-time dependency setup.
- Keep SNI worker sizing RAM-only so swap does not increase scan concurrency.

## [1.0.3] - 2026-11-11

- Lower KNS memory preflight thresholds for read-only discovery and routine node changes so small-memory LXC probes are less likely to be blocked.
- Keep a separate 64 MiB reserve for sing-box kernel upgrades and first-time dependency initialization.
- Include measured available memory and the operation threshold in KNS resource errors.

## [1.0.2] - 2026-11-11

- 默认根据 OneBox 当前公网出口 IP 所在地区优选 Reality SNI 候选。
- 同证书链等级内优先地区匹配项，再按连接耗时排序；全球通用候选作为备选。
- 交互菜单默认使用地区自动识别；可通过 `--sni-region` 或 `--sni` 手动指定。
- 地区查询不可用时回退扫描全部地区候选，不阻断安装。
- 在 README 中说明地区识别方式、回退行为及公网出口 IP 查询。
