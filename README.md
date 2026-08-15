# WeChatIngest

iOS 微信侧车采集 + NAS 知识库。和 PKC 一起注入同一个微信：PKC 继续负责群里的触发回复，本插件只记录，**永不自动回私聊**。

```text
微信 (TrollFools / 全能签注入 dylib)
        │  SFTP
        ▼
NAS  待入库/<uuid>.json [+ 媒体]
        │  consumer.py --watch
        ▼
群聊|私聊|公众号 / 消息.jsonl + 索引.sqlite
        │  Docker 只读
        ▼
网页控制台 :18791
```

当前公开快照：插件 dylib **1.5.31**，控制台 **1.5.11**。目标微信约 **8.0.75**。

---

## 它做什么

- 记录已勾选的群，以及全部私聊：文本、图片、语音、视频、表情、文件、红包、撤回、公告。
- 媒体经 SFTP 落到 NAS，按会话分到 `图片/` `语音/` `视频/` `文件/`。
- 网页控制台按微信会话方式只读查看；语音 silk 在 NAS 转 wav，视频点卡片弹出播放。
- 爱思导出的 Documents 包可在 NAS 一次性导入，补历史。

不做什么：不发消息、不回私聊、不替代 PKC、不在手机上解 wxgf。

---

## 仓库里有什么

| 目录 | 作用 |
|---|---|
| `tweak/` | iOS dylib，ObjC runtime swizzle，不链 CydiaSubstrate |
| `store/` | NAS 入库、爱思导入、CLI |
| `console/` | 只读网页（stdlib HTTP + Docker） |
| `policy/` | 采集策略；单测锁死「不回私聊」 |
| `deploy/` | systemd / 用户态安装脚本 |
| `scripts/build-dylib.sh` | Mac 打 arm64 dylib |
| `docs/` | 脱密开发与部署文档 |

---

## 文档（全部脱密，可公开）

| 文档 | 内容 |
|---|---|
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | 架构、类型映射、代码从哪改、已知限制 |
| [docs/DEPLOY-FNOS.md](docs/DEPLOY-FNOS.md) | **飞牛 NAS 部署全文**：目录、systemd、Docker、frp、爱思导入、排障 |
| [docs/install-quanqian.md](docs/install-quanqian.md) | 全能签注入微信 |
| [docs/install-trollfools.md](docs/install-trollfools.md) | TrollFools 注入 |

自己机器上的 IP、账号、路径不要写进本仓库。

---

## 最短部署

### 1. 手机插件

Mac 上（需要 Xcode iphoneos SDK）：

```bash
bash scripts/build-dylib.sh
# 得到 build/WeChatIngest.dylib 和 build/WeChatIngest-<版本>.dylib
```

用全能签或 TrollFools 注入 `com.tencent.xin`。入口：**我 → 插件 → 微信记忆**。  
填 NAS 的 SSH（内网 IP:22，或 frp 域名:映射端口）、能写 inbox 的用户和密码。打开「启用全量记录」，点「测试 SSH」。

细节：[install-quanqian.md](docs/install-quanqian.md)

### 2. NAS 入库

```bash
export WECHAT_INGEST_ROOT=/path/to/data
mkdir -p "$WECHAT_INGEST_ROOT"/{待入库,群聊,私聊,公众号}
# 推荐常驻：
python3 store/consumer.py --watch
# 或：
bash deploy/install-user.sh
```

完整步骤、systemd 单元、防火墙和排障表见 **[docs/DEPLOY-FNOS.md](docs/DEPLOY-FNOS.md)**。

### 3. 只读控制台

```bash
cd console
cp .env.example .env          # 填登录名、密码、自己的 wxid
# docker-compose.yml 里把数据目录挂到 /data
docker compose up -d --build
# 浏览器打开 http://<NAS局域网IP>:18791
```

改网页：`docker cp console/static/index.html <容器>:/app/static/index.html`  
改 Python：`docker cp` 之后必须 `docker restart`。

---

## 硬规则

- 不自动回私聊，发送路径必须过 `SendGate`
- 未知微信类型存成 `raw`，不要丢
- 控制台只读，不能从网页发微信
- 不要提交 `.env`、聊天 jsonl、爱思包、微信 IPA、真实密码

---

## 许可

个人工具，无担保。libssh2 / mbedtls 遵循各自许可证，预编译头和库在 `third_party/ios-arm64/`。
