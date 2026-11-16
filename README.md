# VPS-FW

Debian 13 VPS 防火墙终端面板，使用 Bash、nftables 和 systemd。当前版本 **v3.1.2**。

> **严格隔离模式：** 未确认超时或检测到配置损坏时会阻断非回环 IP 流量，包括已有 SSH。不会自动撤掉保护。首次部署和故障恢复请使用商家的 VNC 控制台。

## 安装前准备

- 使用 Debian 13 VPS，准备 root 权限和可访问 GitHub 的网络。
- **先确认商家提供的 VNC 控制台能够登录**，包括账号和密码。隔离会切断 SSH，也会切断 VPS 内自行运行的 VNC 网络服务。
- 确认 SSH 实际监听端口，并了解当前连接的公网出口 IP。动态 IP 或代理出口变化可能使 SSH 白名单失效。
- 应用规则时网络可能短暂中断；请避开交易关键时段，并先在测试 VPS 上验证。

## 首次安装并打开面板

连接 VPS，在交互终端执行以下命令。命令会下载安装器，校验并安装主脚本，然后打开面板：

```bash
curl -fsSL 'https://raw.githubusercontent.com/AlanWalkBill123/vps-fw/8c2252b151d42035f927bc843c05c896f209150e/install-vps-fw.sh' | sudo bash -s -- 'https://raw.githubusercontent.com/AlanWalkBill123/vps-fw/8c2252b151d42035f927bc843c05c896f209150e/vps-fw.sh' '12b2ea24498481d6ea3a0601ef9e45e1f149187becd78a010c098d601a75fc32'
```

已登录为 `root` 时可去掉 `sudo`。如果提示 `curl: command not found`，先安装 curl：`apt update && apt install -y curl`（非 root 用户请使用 sudo）。

安装器和主脚本地址固定到同一提交；安装器会核验主脚本的 SHA256。管道中首次下载的安装器自身没有预先校验，需要信任其来源。希望先审阅安装器时，可下载并独立核验后再执行：

```bash
curl -fsSL 'https://raw.githubusercontent.com/AlanWalkBill123/vps-fw/8c2252b151d42035f927bc843c05c896f209150e/install-vps-fw.sh' -o install-vps-fw.sh
# 先审阅 install-vps-fw.sh，并通过可信渠道独立核验其 SHA256
sudo bash install-vps-fw.sh 'https://raw.githubusercontent.com/AlanWalkBill123/vps-fw/8c2252b151d42035f927bc843c05c896f209150e/vps-fw.sh' '12b2ea24498481d6ea3a0601ef9e45e1f149187becd78a010c098d601a75fc32'
```

安装后，**以后打开面板只需运行**：

```bash
sudo fw
```

如果已经是 `root`，运行 `fw` 即可。退出面板不会停止已经应用的防火墙。

## 首次配置、应用和确认

1. 按向导核对公网网卡和 SSH 端口；如选择 SSH 白名单，确认其中包含你当前连接所用的公网出口 IP。
2. 应用规则后，保持原窗口和商家控制台可用，**新开一个 SSH 窗口**验证能否登录。仅有原连接正常不代表新连接一定可用。
3. 在面板显示的倒计时内，进入菜单 `[6]` 按提示确认；也可以在新窗口执行：

   ```bash
   sudo fw confirm
   ```

   已是 `root` 时运行 `fw confirm`。确认后检查面板，确保不再显示等待确认。
4. 默认确认期限为 300 秒；到期或待确认时重启会隔离非回环网络，包括已有 SSH。需要通过商家控制台恢复，不会自动放开公网。

应用过程中可能出现“应用事务进行中”的隔离提示；请结合后续是否显示应用成功、面板状态及倒计时判断，仍须验证新连接并确认。

## 常用命令与恢复

| 目的 | 命令 | 说明 |
| --- | --- | --- |
| 打开面板 | `sudo fw` | root 用户可直接输入 `fw` |
| 确认待确认规则 | `sudo fw confirm` | 先用新 SSH 连接验证 |
| 检查健康状态 | `sudo fw health` | 通过时输出 `PASS` |
| 查看状态 | `sudo fw status` | 查看面板状态及规则 |
| 查看历史版本 | `sudo fw generations` | 列出可用于恢复的版本 ID |
| 恢复历史版本 | `sudo fw recover 版本ID` | 需在控制台核对；应用后仍需确认 |

如已隔离，通过商家 VNC 登录：没有待确认修改且保存配置完整时可执行 `sudo fw restore`；超时后用 `sudo fw` 打开面板，核对草稿，在菜单 `[6]` 按提示重新应用并确认。配置损坏时参考[完整恢复步骤](docs/operations.txt)。

`sudo fw lockdown` 会隔离所有非回环流量，交互终端需输入 `YES`；`--yes` 或非交互调用直接执行。`rollback` 和 `emergency-off` 也是隔离命令，**不会撤掉防护**。

本地预览界面可下载仓库中的 `vps-fw.sh`、核验 [SHA256SUMS](SHA256SUMS) 后运行 `bash vps-fw.sh --demo --no-tty`；演示不会安装防火墙。

## 已安装旧版本，如何更新？

1. 在面板确认没有“等待确认”的倒计时。若仍在倒计时中，先验证新 SSH 连接并运行 `sudo fw confirm`；已隔离时先通过商家控制台按恢复步骤处理。
2. 备份现有配置（备份包含管理 IP 等信息，请勿上传公开仓库）：

   ```bash
   sudo tar -czf /root/vps-fw-backup-$(date +%Y%m%d-%H%M%S).tar.gz -C /etc vps-fw
   ```

3. 重新运行本页“首次安装并打开面板”中的一键命令。安装器会校验新版并替换程序；无需卸载旧版，现有配置会保留。
4. 检查面板标题是否为 **v3.1.2**。以后仍用 `sudo fw` 打开面板；root 用户直接运行 `fw`。

**v3.1.1 → v3.1.2 仅更新显示和日志措辞，不改变过滤策略，无需为本次界面更新重新应用规则。** 如果你在面板里修改了草稿，则仍须通过 `[6]` 应用，并按提示确认。

本版把 SSH 专用策略列入安全组视图，并在列表下方逐条显示未应用的新增、删除、修改及顺序变化。SSH 策略继续在 `[4]` 管理，不会变成可用普通 ID 删除的规则。正常应用时的临时隔离提示改为 `[INFO]`，故障隔离仍是 `[ERR]`。

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
python3 tests/test_ui.py
```

以上测试使用临时目录与模拟命令，不安装防火墙，不访问 GitHub。安装器测试需要支持 PTY 的 Unix 环境。测试范围和真实 Debian 虚拟机验证摘要见 [测试说明](docs/TESTING.md)。
