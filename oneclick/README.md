# 一键安装与管理

## 最快使用

运行以下命令下载并打开菜单：

```bash
curl -fL https://raw.githubusercontent.com/ffoocn/cn-egress-oneclick/main/cn-egress-oneclick.sh -o cn-egress-oneclick.sh && chmod +x cn-egress-oneclick.sh && ./cn-egress-oneclick.sh
```

`-o` 指定保存文件；不带它只会将脚本打印到终端。`-f` 遇到 HTTP 错误会停止，避免继续执行错误页面。此命令先打开菜单；选择安装才会部署服务。 首次运行会自动检测并补装管理机缺少的依赖，完成后继续打开菜单。

在能 SSH 访问三台机器的 Linux 或 macOS 管理电脑上，也可直接运行下载好的文件：

```bash
bash cn-egress-oneclick.sh
```

首次选择 **1 配置 SSH 节点**，然后选择 **2 一键安装 / 接管现有部署**。默认值为示例地址：香港 `203.0.113.10`、大陆中转 `198.51.100.20`、内网出口 `192.168.1.2`；请替换为自己的三台机器和 SSH 用户名。这些示例值不代表可连接的服务。大陆只配置一个节点，上海或北京二选一。输入密码时不会回显，密码只在本次进程及受限临时文件中使用，退出时清理，不写入安装脚本或持久节点配置。

已有完整部署时，安装会接管管理，保留现有服务器密钥、证书、手机配置和运行中的服务。不会为了接管而重启 VPN。全新机器会自动生成独立 WireGuard 密钥、双向 TLS 证书及 iPhone、Android、Windows 配置。

中央菜单包括状态、诊断、启动、停止、重启、日志、备份、客户端列表、新增、导出、撤销、卸载和回滚未完成安装。操作当前三台机器后，可在每台节点上单独运行：

```bash
sudo cn-egress
```

本机菜单只管理当前节点；停止或重启会短暂中断经过该节点的 VPN 用户。

## 运行条件

- 管理电脑：启动时自动检查 Python 3.9+（完整标准库）、SSH 客户端、OpenSSL 和 Linux CA 证书包。缺少时使用当前系统软件源补装，再自动进入菜单；已有依赖会直接使用，不需要 pip。Linux 支持 APT、DNF / YUM、APK；macOS 使用已安装的 Homebrew。自动安装需要 root 或可用的 sudo，Homebrew 使用普通用户。
- 三个节点：运行 systemd 的 Debian / Ubuntu Linux，并已有可用的 Python 3.9+；当前版本节点安装支持 x86_64。管理机的启动依赖检查和节点安装是两步操作。脚本在依赖缺失时只安装所需软件包；软件索引缺失时刷新 APT 索引并重新检查最小安装计划。如现有 APT / dpkg 未完成或安装会升级已有软件，会停止并说明原因，避免修复或升级原有环境。
- 国内出口机需已启用 IPv4 转发。自动安装不会将原本关闭的宿主转发改为开启，因为该参数变化可能重置其他 IPv4 设置。[Linux 内核说明](https://docs.kernel.org/networking/ip-sysctl.html)
- 管理电脑能访问三台机器的 SSH，包括 `192.168.1.2`。适合在国内办公室网络运行；远程管理需已有管理网络。脚本不会开放 NAS 的公网 SSH。
- 云安全组允许香港用户端口 UDP51820、大陆 WSS 端口 TCP443。云控制台规则不由脚本修改；本机端口已占用时会在安装前停止。
- 大陆中转只能填写一个节点。若选北京，在配置中替换 `sh.host`，不要同时填写上海和北京。现有部署更换中转属于迁移，工具会拒绝自动覆盖不完整或混合的三节点部署。

Linux 安装前会检查软件包方案；软件源没有兼容 Python、软件包状态未完成，或方案需要升级 / 删除已有软件时，会说明原因并停止。macOS 交由已有的 Homebrew 安装缺少的工具及必要依赖。不自动更换软件源或替换系统 Python。

## 命令方式

单文件脚本首次解压到 `~/.local/share/cn-egress-oneclick`，再次运行会更新工具代码并保留其 `private/`。同一目录已有管理菜单运行时，会提示先退出，避免更新正在使用的程序。可用环境变量 `CNE_HOME` 指定另一个管理目录。解压 ZIP 包则在目录内运行 `bash cn-egress.sh`，功能相同。

```bash
bash cn-egress-oneclick.sh setup
bash cn-egress-oneclick.sh install
bash cn-egress-oneclick.sh status
bash cn-egress-oneclick.sh doctor
bash cn-egress-oneclick.sh restart
bash cn-egress-oneclick.sh logs --target sh
bash cn-egress-oneclick.sh backup
bash cn-egress-oneclick.sh client list
bash cn-egress-oneclick.sh client add Alice-iPhone
bash cn-egress-oneclick.sh client export Alice-iPhone
bash cn-egress-oneclick.sh client remove Alice-iPhone
```

`--target hk|sh|exit|all` 选择管理节点；默认 all。本机命令支持 `sudo cn-egress status`、`doctor`、`start`、`stop`、`restart`、`logs`、`backup`、`uninstall`。

节点地址和 SSH 私钥路径保存在 `private/topology.json`。可参考 `topology.example.json`；配置只接受节点信息，不接受明文密码。旧部署的 iPhone / Android / Windows 等原客户端在列表中显示，但不被当作新工具创建的用户撤销。它们的原配置继续使用；控制器不能从服务器找回终端私钥。需要新设备时使用 `client add`。

导出文件可直接导入 WireGuard。管理电脑已安装 `qrencode` 时同时生成 PNG 二维码，未安装则仅导出 `.conf`，不影响导入。标准 Windows 全隧道可能中断公网 RDP，测试应通过云控制台 VNC 启停，详见原 Windows 测试说明。

## 安装失败、备份与卸载

新安装前先检查三节点，再按大陆、出口、香港的顺序安装。每台节点安装前创建管理员权限备份。某节点安装失败会回滚本次写入；如果其他节点已安装，或 SSH 响应丢失，可运行：

```bash
bash cn-egress-oneclick.sh rollback-install
```

该命令只回滚安装记录中同一 deployment_id 的全新部署，不卸载接管的现有部署或其他安装。网络仍不可达时保留待恢复记录；恢复 SSH 后重复运行。回滚后记录与密钥留在私有历史目录，重新安装使用新的证书目录。不能通过删除待恢复记录强行覆盖旧部署。

`backup` 会在各服务器 `/root/cn-egress-oneclick-backup-*` 保存服务配置及网络快照，并在控制器 `private/backups/` 保存本地配置、客户端密钥和 CA。备份及配置权限受限，但包含可用私钥，需按管理员资料保管。新部署的 CA 私钥留在中央 `private/pki/`，供证书维护；既有部署的原 CA 签名私钥不存在，接管不会补造它。

卸载必须显式选择菜单并输入 `UNINSTALL`，或运行：

```bash
bash cn-egress-oneclick.sh uninstall --yes
```

卸载先备份、停止自有 VPN，再清理自有接口、规则和配置。不清空全局防火墙，不改变原默认路由，不删除来源不明的系统工具、APT 软件包或旧运行库。卸载节点会使 VPN 不可用，原本的 NAS、Docker 和其他业务保留。备份不自动覆盖整个系统规则，避免覆盖其他服务的后续改动。

## 诊断和验证范围

`doctor` 检查节点服务和配置；完整验证仍需客户端连接后测试实际业务访问。

软件固定使用 [wstunnel v11.0.0 官方发布](https://github.com/erebe/wstunnel/releases/tag/v11.0.0)。包内包含经 SHA256 校验的公开 amd64 安装包，可在新安装时离线复用；其他依赖仍可能需要 APT 网络。所有下载均验证固定版本和架构，不跳过校验。发布包只包含公开代码与公开软件，不含账号密码、真实 WireGuard 配置、客户端私钥或节点证书私钥。
