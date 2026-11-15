# VPS-FW

Debian 13 VPS 防火墙终端面板，使用 Bash、nftables 和 systemd。当前版本 **v3.1.1**。

> **严格隔离模式：** 未确认超时或检测到配置损坏时会阻断非回环 IP 流量，包括已有 SSH。不会自动撤掉保护。首次部署和故障恢复请使用商家的 VNC 控制台。

## 一键启动

在 Debian 13 的交互终端中运行。下面的安装器和主脚本固定到同一提交，安装器校验主脚本 SHA256 后再运行：

```bash
curl -fsSL 'https://raw.githubusercontent.com/AlanWalkBill123/vps-fw/f106a54666ab9f0e0ad2fd7fd929c76bf4f7b86b/install-vps-fw.sh' | sudo bash -s -- 'https://raw.githubusercontent.com/AlanWalkBill123/vps-fw/f106a54666ab9f0e0ad2fd7fd929c76bf4f7b86b/vps-fw.sh' '9be2a73f72b491ffbbc11110838559ab6f7261a1e380de7b8666b21573897d37'
```

安装器自身在管道中未经预先校验，需要信任其来源。更严格的方式是先下载、审阅并独立核验安装器，再执行：

```bash
sudo bash install-vps-fw.sh 'https://raw.githubusercontent.com/AlanWalkBill123/vps-fw/f106a54666ab9f0e0ad2fd7fd929c76bf4f7b86b/vps-fw.sh' '9be2a73f72b491ffbbc11110838559ab6f7261a1e380de7b8666b21573897d37'
```

也可下载仓库中的 `vps-fw.sh`，核验 [SHA256SUMS](SHA256SUMS) 后本地运行：

```bash
sudo bash vps-fw.sh
```

安装后使用 `sudo fw` 打开面板。不需要安装即可预览界面：

```bash
bash vps-fw.sh --demo --no-tty
```

## 应用与恢复

- 应用后用新连接验证访问，再在 300 秒内执行 `sudo fw confirm`。
- 到期后下一次审计检查会隔离网络；审计约每 5 秒执行，不承诺精确到毫秒。
- 待确认状态下重启也会隔离。已有连接不会成为隔离后的例外。
- `sudo fw lockdown` 在交互终端要求输入 `YES`；`--yes` 或非交互调用直接执行隔离；`rollback` 和 `emergency-off` 是隔离命令的兼容别名。
- 无待确认修改且保存版本完整时，可在 VNC 中执行 `sudo fw restore`。
- 超时后通过 VNC 打开 `fw`，在菜单 `[6] -> [3]` 重新应用核对后的草稿，再确认。
- 当前配置损坏时，用 `sudo fw generations` 列出版本，再执行 `sudo fw recover 版本ID`，成功后仍需确认。

完整的安装、迁移、业务绑定与救援步骤见 [操作说明](docs/operations.txt)。

## 从 3.1.0 升级

先准备可登录的商家控制台。新版安装前校验当前保存配置；若发现 `/064` 等前导零前缀或损坏，会拒绝替换现有程序。应先用旧版改为真正需要的十进制前缀、重新应用并确认，再升级。不要手工改校验清单来跳过检查。

安装后仍需重新应用并确认草稿，才会更新保存的规则和 systemd 单元。审计遇到正在进行的事务会短暂跳过；持续占锁达到 120 秒或计时异常会触发隔离。正常审计执行仍有 20 秒超时。

## 业务启动保护

已安装的 Docker/containerd 服务会在应用时添加防火墙启动依赖。交易程序需用实际的 systemd 服务名显式绑定，例如：

```bash
sudo fw bind-service trading.service
```

这不会立即重启业务；下次启动时要求防火墙和健康检查通过。对运行中的业务，故障隔离会断网，不会自动杀掉进程。

## 范围与边界

- 实测 Debian 13 ARM64、nftables 1.1.3、systemd 257、Docker 26.1.5 的单 WAN 和常规 bridge 场景。
- 默认入站/转发拒绝、出站允许。SSH 白名单、独立黑名单和严格出站可在菜单配置。
- 宿主机出站规则覆盖所有接口。严格出站时，访问容器或 VPN 对端也需要明确的目的 IP/CIDR、协议和端口放行；信任接口不自动豁免出站。回环、已建立连接和必要网络控制报文仍按内置规则处理。
- 信任接口完全放行到宿主机的入站，不等于允许 VPN 出口、子网路由或访问容器的转发。
- 多公网接口、Kubernetes、macvlan/ipvlan、host network、自定义桥和其他发行版需另行验证。
- 普通规则保留 established/related；只有隔离模式会切断这些已有连接。
- 本程序不能阻止取得 root 权限的程序删除规则，也不能解决上游带宽被打满的问题。周期审计存在检测间隔。
- 实际交易所 API、WebSocket、DNS、NTP 和重连行为应在部署环境验证。

## 测试

```bash
python3 tests/test_local.py
python3 tests/test_installer.py
```

以上测试使用临时目录与模拟命令，不安装防火墙，不访问 GitHub。安装器测试需要支持 PTY 的 Unix 环境。测试范围和真实 Debian 虚拟机验证摘要见 [测试说明](docs/TESTING.md)。
