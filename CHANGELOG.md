# Changelog

本文件记录 OneBox 的正式版本变更。

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
