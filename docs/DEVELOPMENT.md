# WeChatIngest 开发手册（脱密版）

这份是给别人、公开仓库、另一台电脑上的 AI 用的。  
**不含**真实主机、域名、账号、密码、wxid、私人路径。  
自己下次接着改，用飞牛上的「不脱密/开发手册.md」，或本机 `docs/DEV-INTERNAL.md`。

配套：

- NAS 部署逐步说明 → [DEPLOY-FNOS.md](DEPLOY-FNOS.md)
- 全能签注入 → [install-quanqian.md](install-quanqian.md)
- TrollFools 注入 → [install-trollfools.md](install-trollfools.md)

公开仓库里的插件源码（`tweak/`）**默认不带任何私人服务器地址**。第一次打开「微信记忆」必须自己填 SSH。

当前公开快照：插件 **1.5.32**，控制台 **1.5.12**。目标微信约 **8.0.75**。

---

## 0. 产品一句话

把 iOS 微信里发生的消息，静默抄到 NAS 做成知识库。  
群里的 @ 回复继续由 **PKC** 负责。本插件 **只记录，永不发私聊，也绝不代替 PKC 发群消息**。

---

## 1. 硬规则（改任何代码前）

1. 禁止私聊自动回复。闸门：`policy/send_gate.py`、`tweak/hooks/SendGate.m`、`scripts/check-no-dm-send.sh`。
2. 群回复只走 PKC。本仓库不 hook `sendMsg:toUser:` 去发业务消息。
3. 未知微信 Type 写成 `raw`，`extra_json.raw_type` 留下原值，不要丢。
4. 不在手机上解 wxgf。silk / wxgf 在 NAS 解。
5. 控制台只读，不能从网页发微信。
6. dylib 版本化：`build/WeChatIngest-<ver>.dylib`。控制台版本在 `console/app.py` 的 `VERSION`。
7. 公开 git 不得出现真实密码、私人域名、自己的 wxid、聊天 jsonl、爱思包、微信 IPA。
8. 切蜂窝时禁止在主线程关闭 libssh2。必须 debounce 后只在 SFTP 队列重连。

违反 1、2、7 的 PR 直接拒绝。

---

## 2. 总架构

```text
┌─ iPhone / WeChat (com.tencent.xin) ─────────────────────────┐
│  TrollFools 注入 WeChatIngest.dylib                         │
│  Tweak.m ctor                                                │
│    ├ SettingsUI   我 → 插件 → 微信记忆                       │
│    ├ MessageHooks CMessageMgr 三条选择子                     │
│    ├ MediaExtract 磁盘/KVC 抠媒体                            │
│    ├ SftpInboxClient libssh2 写远端 inbox                    │
│    ├ NetworkPath  en0 / pdp_ip，1.6s 去抖                    │
│    └ UploadHUD    左红右白胶囊                               │
└─────────────────────────── SFTP ────────────────────────────┘
                              │
                              ▼
┌─ NAS ───────────────────────────────────────────────────────┐
│  <DATA>/待入库/<uuid>.json  [+ 同名媒体]                      │
│           │                                                  │
│           ▼ consumer.py --watch                              │
│  群聊|私聊|公众号/<会话>/消息.jsonl                            │
│  图片/语音/视频/文件                                         │
│  索引.sqlite   UNIQUE(chat_id, msg_id)                       │
│  会话对照.json                                               │
│           │                                                  │
│           ▼ Docker wechat-ingest-console :18791              │
│  只读网页。silk 现场转 wav。视频点卡片弹灯箱。                  │
└─────────────────────────────────────────────────────────────┘
```

两端通过 **SFTP 文件** 耦合，没有微信官方 API，没有 HTTP 上传。

---

## 3. 仓库地图（按职责）

### 3.1 `tweak/` — 手机插件

| 文件 | 职责 |
|---|---|
| `Tweak.m` | `__attribute__((constructor))`。装 HUD、网络、设置 hook；2s 后装消息 hook；8s 后状态循环和通讯录同步。 |
| `Settings.h` / `Settings.m` | `NSUserDefaults` 套件 `com.zkx.wechat.ingest`。**不写 PKC 的 key。** |
| `hooks/MessageHooks.m` | swizzle `CMessageMgr` 三个方法，映射成 event，丢给 SFTP。 |
| `hooks/MediaExtract.m` | 从 wrap / `Documents/<32hex>/{Img,Audio,Video,OpenData}` 找文件。 |
| `hooks/SftpInboxClient.m` | 串行队列 SFTP；`applyCurrentEndpoint` / `reconnectOnQueue`。 |
| `hooks/Libssh2SftpChannel.m` | 对 libssh2 的薄封装。 |
| `hooks/NetworkPath.m` | `getifaddrs`：`en0`=Wi-Fi，`pdp_ip*`=蜂窝。稳定 1.6s 才切。 |
| `hooks/UploadHUD.m` | 悬浮胶囊，拖、捏合、隐藏。 |
| `hooks/UploadStats.m` | 今日/周/年，按类型和 wifi/wwan 计数。 |
| `hooks/SettingsUI.m` | 插件页 UI。版本字符串在这里。 |
| `hooks/SendGate.m` | 发送闸门，默认挡住私聊发送。 |
| `hooks/OpenClawReply.m` | 预留协议 3，默认不走私聊。 |
| `hooks/Contacts.m` / `ContactPicker.m` | 备注、选群。 |
| `hooks/StatusSync.m` / `DebugLog.m` | 状态回传、调试日志。 |
| `hooks/HistoryExport*.m` | **产品已下线全量导出**，`build-dylib.sh` 不再链接。 |

注入方式：普通 arm64 dylib + `method_exchangeImplementations`。不链 CydiaSubstrate。

### 3.2 `store/` — NAS 入库

| 文件 | 职责 |
|---|---|
| `consumer.py` | inbox → jsonl + sqlite。`--watch` 常驻。 |
| `media.py` | 目录名、大小上限、`[image]` 占位。 |
| `history_map.py` | 爱思 dump 的 Type → `msg_type`。 |
| `import_ais_dump.py` | 离线全量导入。会 wipe 群聊/私聊/索引。 |
| `transcribe.py` | silk → wav。 |
| `wxgf.py` | 尽力出预览。 |
| `readable.py` | 给人看的 `聊天记录.md`。 |
| `cli.py` | `stats` / `list-chats` / `export` / `search` / `digest`。 |
| `schema.sql` / `event.schema.json` | 契约。 |
| `sftp_inbox.py` | 测试/工具向远端丢 inbox（不是插件本身）。 |

默认数据根由环境变量 `WECHAT_INGEST_ROOT` 决定，代码默认是 `/data/wechat-ingest`。

### 3.3 `console/` — 只读网页

| 文件 | 职责 |
|---|---|
| `app.py` | stdlib `ThreadingHTTPServer`。鉴权、API、silk 转码、raw 分类。 |
| `static/index.html` | 漫画风会话 UI。 |
| `static/logs.html` | 调试日志。 |
| `Dockerfile` / `docker-compose.yml` | 容器。密钥只许放 `.env`。 |
| `.env.example` | 模板。 |

### 3.4 其它

| 路径 | 职责 |
|---|---|
| `policy/` | 采集策略 +「不回私聊」单测。 |
| `contracts/pkc-selectors.json` | 已确认存在的微信/PKC 选择子。 |
| `deploy/` | systemd、用户态安装。 |
| `scripts/build-dylib.sh` | Mac 打 dylib。 |
| `third_party/ios-arm64/` | 预编译 libssh2 + mbedtls。 |
| `skill/wechat-memory/` | OpenClaw 只读技能。 |

---

## 4. 手机运行时序

1. TrollFools 在微信启动时 `dlopen` dylib。
2. `WeChatIngestInitializer`（`Tweak.m`）`dispatch_once`：
   - 挡一部分系统弹窗
   - 主线程：`WXIngestNetwork start`、设置页 hook、HUD
   - 监听 `WXIngestNetworkDidChangeNotification` → SFTP `applyCurrentEndpoint`（队列里）
   - 2 秒后：`WeChatIngestInstallMessageHooks`
   - 8 秒后：状态循环、通讯录同步
3. 微信「我」页被 hook，出现一行 **微信记忆**。
4. 用户必须自己填：内网主机/端口、公网主机/端口、SSH 用户密码、Inbox 路径。默认全空。
5. 打开「启用全量记录」后，新消息才入队。

`CMessageMgr` 被换掉的选择子（`contracts/pkc-selectors.json`）：

- `AddMsg:MsgWrap:`
- `AsyncOnPreAddMsg:MsgWrap:`
- `HandleAppMsg:MsgWrap:`

每个替换 IMP **先** 调回原实现，再 KVC 读 wrap。缺 `m_uiMesLocalID` 的直接丢弃（不当消息）。

KVC 字段：

| key | 用途 |
|---|---|
| `m_uiMessageType` | 微信 Type |
| `m_nsContent` | 文本或 XML |
| `m_nsFromUsr` | 发送者 |
| `m_nsToUsr` | 会话（群是 `数字@chatroom`） |
| `m_uiMesLocalID` | `msg_id` |
| `m_uiCreateTime` | `ts`（没有就 0） |

`toUser` 以 `@chatroom` 结尾 → `chat_kind=group`，否则 `dm`。

---

## 5. 类型映射

微信 Type → 入库 `msg_type`（ObjC 与 `store/history_map.py` / `policy/test_msgwrap_map.py` 必须一致）：

| Type | 条件 | msg_type |
|---|---|---|
| 1 | | text |
| 3 | | image |
| 34 | | voice |
| 43 / 44 / 62 | | video |
| 47 | | emoji |
| 49 | XML 含 `<type>2001</type>` / hongbao / 红包 | redpacket |
| 49 | `<type>6</type>` / `<appattach` / `<fileext>` | file |
| 49 | `<type>4</type>` / `<videomsg` | video |
| 49 | 其它或 XML 为空 | **raw** |
| 10000 | 公告类 | announcement |
| 10002 | 撤回 | revoke |
| 42 | | raw（名片） |
| 48 | | raw（位置） |
| 50 | | raw（语音通话，没有录音） |
| 其它 | | raw，保留 `raw_type` |

媒体占位文本：`[image]` `[voice]` `[video]` `[emoji]` `[file]` `[redpacket]`。

控制台展示时会再分类 raw（见第 10 节），**界面不得再出现字面量 `[raw]`**。

---

## 6. 设置键（`com.zkx.wechat.ingest`）

| key | 类型 | 默认（公开版） |
|---|---|---|
| `ingest.enable` | BOOL | NO |
| `ingest.ssh.host` | string | `""` |
| `ingest.ssh.port` | int | 22 |
| `ingest.ssh.user` | string | `""` |
| `ingest.ssh.password` | string | （空） |
| `ingest.inbox.path` | string | `""`（空则 SFTP 落到 `/data/inbox` 占位，应改成 NAS 真实待入库路径） |
| `ingest.net.auto` | BOOL | YES |
| `ingest.net.lan_host` / `lan_port` | | `""` / 22 |
| `ingest.net.wan_host` / `wan_port` | | `""` / 22 |
| `ingest.record_all_groups` / `record_all_dms` | BOOL | NO |
| `ingest.groups` / `ingest.dms` | 白名单 | |
| `ingest.group_exclude` / `dm_exclude` | 黑名单 | |
| `ingest.media.wifi_only` | BOOL | YES |
| `ingest.media.upload_{image,voice,video}` | BOOL | YES |
| `ingest.media.image_max_mb` | int | 20 |
| `ingest.media.video_max_mb` | int | 50 |
| `ingest.hud.enabled` / `hidden` / `frame` | | YES / NO / 记忆位置 |
| `ingest.collect_officials` | BOOL | NO |
| `ingest.gateway.port` | int | 18790（本机探测，上传不走它） |
| `ingest.token` / `ingest.command.prefix` | | 空 / `/` |

内网判定只看 RFC1918 / 127，**不再写死任何域名**。

---

## 7. SFTP 与切网

- 一个串行 `dispatch_queue`。所有 connect/close/put 都在这条队列。
- `NetworkPath`：`en0` 有 IPv4 → Wi-Fi；`pdp_ip*` → 蜂窝。变化后 **1.6 秒** 内反复跳变忽略。
- 通知发出后，`SftpInboxClient applyCurrentEndpoint` **只在队列里** 重连。
- 1.5.28 之前在主线程 `libssh2` close + 重建 HUD scene = 微信卡死闪退。不要回退。
- 积压：pending 计数，HUD 显示。
- 远端文件：`<inbox>/<uuid>.json`，媒体同 stem 不同后缀。

Inbox 建议填 NAS 上的：

```text
<DATA>/待入库
```

消费者同时认 `待入库/` 和旧名 `inbox/`。

---

## 8. 入库契约

`store/event.schema.json` 必填：`chat_id, chat_kind, msg_id, msg_type, sender, ts`。

`chat_kind` 只能是 `group` | `dm`。公众号在磁盘上是 `公众号/`，库里仍常记 `dm`。

`consumer.py`：

1. 把 json 原子改名进 `待入库/.processing/`
2. 校验字段；未知 `msg_type` → `raw`
3. `media.decide_media` 决定拷不拷
4. 拷到 `<会话>/<图片|语音|视频|文件>/`
5. `INSERT ... ON CONFLICT(chat_id,msg_id) DO UPDATE`，只在旧行没媒体、新行有媒体时补
6. 同样条件下才追加一行 `消息.jsonl`（避免重复）
7. 成功才删 inbox 文件；坏文件进 `待入库/失败/`

常驻：

```bash
WECHAT_INGEST_ROOT=<DATA> python3 store/consumer.py --watch
```

目录名：

| 常量 | 中文 |
|---|---|
| `DIR_GROUPS` | 群聊 |
| `DIR_DMS` | 私聊 |
| `DIR_OFFICIAL` | 公众号 |
| `DIR_INBOX` | 待入库 |
| `FILE_EVENTS` | 消息.jsonl |
| `FILE_INDEX` | 索引.sqlite |
| `FILE_CHATS` | 会话对照.json |

---

## 9. 控制台后端

`console/app.py`，无 pip。环境变量：

| 变量 | 含义 | 公开默认 |
|---|---|---|
| `WECHAT_INGEST_ROOT` | 数据根 | `/data` |
| `CONSOLE_PORT` | 端口 | 18791 |
| `CONSOLE_USER` / `CONSOLE_PASSWORD` | 登录 | `admin` / **必须设** |
| `CONSOLE_SECRET` | session HMAC | 随机 |
| `WECHAT_SELF_WXID` / `WECHAT_SELF_NAME` | 自己 | 空 |
| `SILK_DECODER` | silk 可执行文件 | `/usr/local/bin/silk-decoder` |
| `CONSOLE_LAN_URL` / `CONSOLE_PUBLIC_URL` | 展示用 | `http://127.0.0.1:18791` / 空 |

主要路由：

| 路径 | 作用 |
|---|---|
| `GET /` | 控制台 HTML |
| `GET/POST /login` `/logout` | 登录 |
| `GET /api/health` | `{ok, version}` |
| `GET /api/status` | 插件在线、条数（sqlite COUNT，禁止扫 jsonl） |
| `GET /api/chats` | 会话列表；每会话只读 jsonl **尾巴** 取最后一条 |
| `GET /api/chats/{kind}/{folder}/messages?limit=&before_ts=&before_id=` | 消息页 |
| `GET /media/...` | 媒体；`.aud` 现场 silk→wav |

翻页：

- 先读文件尾巴，字节数按 `limit` 放大，不够就倍增，上限约 24MB。
- `before_ts` + `before_id` 取更早的一页。
- 多读 1 条用来算 `has_more`。
- **禁止** 前端 `limit+=80` 封顶 200——会点了没反应。

`classify_raw`（展示层，不改磁盘）：

| 情况 | 结果 |
|---|---|
| 后缀 mp3/m4a/wav/aac/ogg/aud/silk | 当 voice 播 |
| mp4/mov | 当 video |
| 有其它文件 | file，显示文件名 |
| raw_type 50 | `[语音通话]` |
| 48 | `[位置]` |
| 42 / 66 | `[名片]` |
| 49 无文件 | `[卡片消息]` |

爱思 dump 里约几十万条 type 49 的 XML 是 zstd dict-id 5，IPA 里 `MsgDict.zstd` 加密，解不开。这些不是坏掉的语音条。type 50 没有可播录音。

---

## 10. 控制台前端（`static/index.html`）

- 布局：rail + 会话列表 + 消息。`.app` 必须 `grid-template-rows: minmax(0,1fr)`，`.msgs` `flex:1 1 0; min-height:0`，否则不能滚。
- 视频：约 240×170 预览 + 播放钮，点开 `#box` 灯箱。不要 88×88 内嵌 `controls`。点 `<video>` 本身不关灯箱。
- 语音：微信条，点一下 `fetch` blob 播放。`/media` 会把 silk 转成 wav。
- 「更早的消息」调 `before_ts/before_id`，顶部显示「正在加载… / 没有更早的了」。
- 20s 轮询只合并新尾巴，不要把已翻上去的页冲掉。

热更新：

```bash
docker cp console/static/index.html <容器>:/app/static/index.html   # 强制刷新即可
docker cp console/app.py <容器>:/app/app.py && docker restart <容器>
```

---

## 11. 爱思离线导入

`store/import_ais_dump.py`：

- 表：`Chat_<md5(username)>`，**排除** `ChatExt2_*`。
- `Des=0` 自己，`Des=1` 对方（dump 约定）。
- 媒体：`{Img,Audio,Video,OpenData}/<md5>/<MesLocalID>.*`，去掉 thumb。
- Message 若以 `28 b5 2f fd` 开头是 zstd；没字典就空字符串，`compressed_empty++`。
- **会清空** `群聊/` `私聊/` `公众号/` `索引.sqlite`。先停 consumer，确认 `--root`。
- `WECHAT_SELF_WXID` / `WECHAT_SELF_NAME` 用环境变量，不要把真人 wxid 写回公开默认值。

---

## 12. 编译插件（脱密版）

Mac + Xcode iphoneos SDK：

```bash
bash scripts/build-dylib.sh
# build/WeChatIngest.dylib
# build/WeChatIngest-1.5.32.dylib
```

脚本会链 `third_party/ios-arm64/lib/libssh2.a` 和 mbedtls。缺库先跑 `scripts/build-ios-libssh2.sh`。

公开 dylib **没有**预置 NAS 地址。注入后打开「微信记忆」自己填。已经装过旧版、手机 defaults 里存过地址的，不受这次清空默认值影响。

升版本要一起改：

- `scripts/build-dylib.sh` 的 `VERSION`
- `tweak/hooks/SettingsUI.m` 的 `WXIngestPluginVersion`
- `tweak/Tweak.m` 日志
- `store/test_plugin_net_hud.py` 里的版本断言

---

## 13. 测试

```bash
python3 -m pytest console/test_app.py store/test_media.py store/test_import_ais_dump.py \
  store/test_plugin_net_hud.py policy deploy/test_units.py -q
```

`store/test_consumer.py` 里有几条还在测已退役的 `wxhist-*.jsonl` 全量包，和现在「live 只吃 `*.json`」不一致，不必为了公开版去复活那条路径。

活 PKC 选择子扫描：设置 `PKC_DYLIB` 再跑 `contracts/test_pkc_selectors.py`。没设就 skip。

`scripts/check-no-dm-send.sh` 必须保持绿。

---

## 14. 给下一任 AI 怎么改

1. 先读本文件 + `event.schema.json`。
2. 只改气泡/灯箱/语音条 → `console/static/index.html`，docker cp，浏览器点一遍。
3. 改翻页/鉴权/raw 分类 → `console/app.py` + `console/test_app.py`，restart 容器。
4. 改入库 → 先补 `store/test_*.py`。
5. 改 hook → `contracts/pkc-selectors.json` 对过选择子，再动 `MessageHooks.m`，再 `build-dylib.sh`。
6. 「帮我自动回私聊」→ 拒绝。
7. 不要把真人密码、域名写进 git。

---

## 15. 已知限制

- `MsgDict.zstd` 未解密 → 压缩 XML 没有发送者前缀和卡片标题。
- type 50 是通话记录，不是语音条。
- 部分群文件夹可能仍是 `@chatroom` 数字 id。
- wxgf 预览尽力而为。
- 微信大版本更新后选择子可能失效，重新注入同一 dylib；类改了再改 hook。
- 公开默认 SSH/Inbox 为空，不填就传不上去。这是有意的。

---

## 16. 明确不要做

- 公开 fork 提交 `.env`、jsonl、爱思 zip、IPA、不脱密手册。
- 再写一套会发消息的机器人进这个 dylib。
- `/api/status` 全表扫 jsonl。
- 主线程关闭 libssh2。
- 把「更早的消息」改回 `msgLimit += 80` 封顶 200。
