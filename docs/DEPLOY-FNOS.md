# fnOS / NAS 部署教程（脱密版）

这份只讲 **NAS 端**：inbox 消费、只读控制台、可选 frp、silk 解码。  
不含真实 IP、域名、账号、密码。手机注入见 [install-quanqian.md](install-quanqian.md)。

假设：

- 机器是飞牛 NAS（Debian 系，有 Docker）。
- 你有一个普通用户，下文写成 `<USER>`。
- 代码将放在 `/home/<USER>/wechat-ingest`。
- 数据单独放一块盘，下文写成 `<DATA>`，例如 `/vol1/1000/wechat-ingest-data`。

---

## 0. 架构一眼看懂

```text
手机微信 + WeChatIngest.dylib
        │  SFTP（内网 22 或 frp 映射端口）
        ▼
<DATA>/待入库/<uuid>.json  +  同名媒体
        │  systemd user: consumer.py --watch
        ▼
<DATA>/群聊|私聊|公众号/…/消息.jsonl
<DATA>/索引.sqlite
        │  Docker 只读挂载
        ▼
wechat-ingest-console :18791
        │  可选 frp
        ▼
家里浏览器 / 公网浏览器
```

控制台 **不能发微信**，只是查看器。

---

## 1. 准备目录

```bash
sudo mkdir -p /home/<USER>/wechat-ingest
sudo chown -R <USER>:<USER> /home/<USER>/wechat-ingest

sudo mkdir -p <DATA>/{待入库,群聊,私聊,公众号,status}
sudo chown -R <USER>:<USER> <DATA>
```

把本仓库放到 `/home/<USER>/wechat-ingest`（git clone 或 scp）。

插件 SFTP 写入的 inbox 必须是 `<DATA>/待入库`。旧文档里的 `inbox/` 名字消费者仍兼容，但新部署请用中文目录，和 `store/consumer.py` 默认一致。

---

## 2. 系统依赖

```bash
sudo apt-get update
sudo apt-get install -y python3 python3-venv openssh-server
```

SSH 必须开着：插件用密码登录 SFTP。建议：

- 单独一个只能写 `<DATA>/待入库` 的用户（更稳），或
- 直接用 `<USER>`，并保证该用户对 `<DATA>` 可写。

确认本机 SSH：

```bash
sshd -T | grep -E 'port|passwordauthentication'
# PasswordAuthentication yes
```

防火墙放行：

| 用途 | 默认端口 | 说明 |
|---|---|---|
| SSH / SFTP | 22 | 插件上传 |
| 控制台 | 18791 | 浏览器 |
| 公网 SSH（可选） | 你在 frp 里映射的端口 | 蜂窝上传 |
| 公网控制台（可选） | 你在 frp 里映射的端口 | 外网看记录 |

---

## 3. 安装入库守护进程

仓库自带用户态脚本（不需要 root systemd）：

```bash
export WECHAT_INGEST_ROOT=<DATA>
bash /home/<USER>/wechat-ingest/deploy/install-user.sh
```

它会：

1. 写 `~/.config/systemd/user/wechat-ingest.service` + `.path`
2. `systemctl --user enable --now wechat-ingest.path`
3. 必要时加一条每分钟 cron 兜底

生产上更稳的做法是 **常驻 watch**（当前推荐）：

```bash
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/wechat-ingest.service <<EOF
[Unit]
Description=WeChat ingest inbox consumer (user)

[Service]
Type=simple
Restart=always
RestartSec=2
Environment=WECHAT_INGEST_ROOT=<DATA>
WorkingDirectory=/home/<USER>/wechat-ingest/store
ExecStart=/usr/bin/python3 /home/<USER>/wechat-ingest/store/consumer.py --watch

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now wechat-ingest.service
loginctl enable-linger <USER>   # 退出 SSH 也继续跑
```

看日志：

```bash
journalctl --user -u wechat-ingest.service -f
```

应出现：

```text
wechat-ingest: watch root=<DATA> workers=1 interval=0.4
```

冒烟：

```bash
python3 - <<'PY'
import json, uuid, os
from pathlib import Path
root = Path(os.environ["WECHAT_INGEST_ROOT"])
inbox = root / "待入库"
inbox.mkdir(parents=True, exist_ok=True)
p = inbox / (uuid.uuid4().hex + ".json")
p.write_text(json.dumps({
    "chat_id": "smoke@chatroom",
    "chat_kind": "group",
    "msg_id": "smoke-1",
    "msg_type": "text",
    "sender": "wxid_smoke",
    "ts": 1720000001,
    "text": "fnos ingest smoke",
}, ensure_ascii=False), encoding="utf-8")
print(p)
PY

sleep 1
ls <DATA>/群聊
python3 /home/<USER>/wechat-ingest/store/cli.py stats
```

`WECHAT_INGEST_ROOT` 要和 consumer 一致。

---

## 4. silk 解码器（语音能在网页里播）

控制台读到 `.aud` / silk 时会调用外部解码器转 wav。把可执行文件放到例如：

```text
/home/<USER>/wechat-ingest/tools/silk-decoder
chmod +x /home/<USER>/wechat-ingest/tools/silk-decoder
```

容器里通过只读挂载变成 `/usr/local/bin/silk-decoder`。没有这个文件，语音条还在，但点了可能播不了。

---

## 5. 控制台 Docker

```bash
cd /home/<USER>/wechat-ingest/console
cp .env.example .env
# 编辑 .env：用户名、密码、自己的 wxid、展示用的内外网 URL
```

`.env` 最少：

```dotenv
WECHAT_INGEST_ROOT=/data
CONSOLE_PORT=18791
CONSOLE_LAN_URL=http://<NAS_LAN_IP>:18791
CONSOLE_PUBLIC_URL=http://<可选公网主机>:<端口>
SILK_DECODER=/usr/local/bin/silk-decoder
WECHAT_SELF_WXID=<自己的wxid>
WECHAT_SELF_NAME=<自己的微信名>
CONSOLE_USER=<网页登录名>
CONSOLE_PASSWORD=<强密码>
CONSOLE_SECRET=<随机长字符串>
```

`docker-compose.yml` 把 `<DATA>` 挂到容器 `/data`。按你的盘改 volumes：

```yaml
volumes:
  - <DATA>:/data
  - /home/<USER>/wechat-ingest/tools/silk-decoder:/usr/local/bin/silk-decoder:ro
```

启动：

```bash
cd /home/<USER>/wechat-ingest/console
docker compose up -d --build
docker ps | grep wechat-ingest-console
curl -I http://127.0.0.1:18791/login
```

浏览器打开 `http://<NAS_LAN_IP>:18791`，用 `.env` 里的用户名密码登录。

飞牛 Docker UI 用户：把 `console/` 拷到例如 `/vol1/1000/docker/wechat-ingest-console/`，在 UI 里用同一份 compose 启动，端口 18791，数据卷指向 `<DATA>`。

---

## 6. 热更新（改完网页 / Python 不必重建镜像）

```bash
# 只改了 HTML/CSS/JS
docker cp /home/<USER>/wechat-ingest/console/static/index.html \
  wechat-ingest-console:/app/static/index.html
# 浏览器强制刷新

# 改了 app.py
docker cp /home/<USER>/wechat-ingest/console/app.py \
  wechat-ingest-console:/app/app.py
docker restart wechat-ingest-console
```

镜像 tag 可能落后于 `app.py` 的 `VERSION`，以容器内文件为准。

---

## 7. 可选：frp 公网

蜂窝上传和外出查看需要两条映射，例如：

| 本机 | 远程 | 用途 |
|---|---|---|
| `127.0.0.1:22` | 公网端口 A | 插件 SFTP |
| `127.0.0.1:18791` | 公网端口 B | 控制台 |

插件设置：

- 内网主机 = NAS 局域网 IP，端口 22
- 公网主机 = 你的域名，端口 A
- 打开「自动切换」

控制台 `.env` 的 `CONSOLE_PUBLIC_URL` 只是展示，真正通不通取决于 frp。

---

## 8. 手机插件怎么对上 NAS

公开仓库打出来的 dylib（1.5.32+）**默认主机、用户、Inbox 全是空的**，必须手填：

1. 打开微信「我 → 插件 → 微信记忆」
2. 内网主机 = NAS 局域网 IP，端口一般 `22`
3. 公网主机 = 你的域名（没有就留空，关掉自动切换）
4. SSH 用户和密码 = 能写 `<DATA>/待入库` 的账号
5. Inbox = `<DATA>/待入库`（消费者也认旧名 `inbox`）
6. 打开「启用全量记录」
7. 勾选群；私聊建议全开
8. 「测试当前线路」成功后，在已选群发一条测试

NAS 上应立刻看到：

```bash
ls <DATA>/待入库
journalctl --user -u wechat-ingest.service -n 50
```

几秒后测试句出现在控制台对应会话。

---

## 9. 爱思历史一次性导入

只在 NAS 上做，不要让手机解 20G+ 库。

1. 把爱思导出的 Documents 包放到 `<DATA>/历史记录/`（zip 即可）。
2. 确认 `store/import_ais_dump.py` 的 `SELF_WXID` 环境变量或脚本常量是你自己的 wxid。
3. **会清空** `群聊/` `私聊/` `公众号/` `索引.sqlite` 再重建。先停 consumer，并确认路径没写错。
4. 运行：

```bash
export WECHAT_INGEST_ROOT=<DATA>
cd /home/<USER>/wechat-ingest/store
python3 import_ais_dump.py <DATA>/历史记录/<dump目录或zip解开的根>
```

5. 看日志里的 `chats` / `messages` / `media` / `compressed_empty`。
6. 再启动 consumer。之后手机新消息会按 `UNIQUE(chat_id,msg_id)` 增量合并。

`compressed_empty` 很大是正常的：微信用 zstd 字典压了图片/语音/卡片 XML，公开字典解不开。这些行仍在，类型靠 Type 字段；type 49 会显示成「卡片消息」。

---

## 10. 日常维护

```bash
# 还在跑吗
systemctl --user status wechat-ingest.service
docker ps | grep wechat-ingest-console

# 积压
ls <DATA>/待入库 | wc -l

# 体量
python3 /home/<USER>/wechat-ingest/store/cli.py stats

# 控制台版本
curl -u '<USER>:<PASS>' http://127.0.0.1:18791/api/health
```

磁盘：媒体在会话目录的 `图片/语音/视频/文件`。控制台转出来的 `.wav` 会写在语音文件旁边，占额外空间。

备份：停 consumer 后拷 `<DATA>`（至少 `索引.sqlite`、`会话对照.json`、`群聊`、`私聊`）。`待入库` 有文件说明还有没吃完的包。

---

## 11. 常见故障

| 现象 | 查 |
|---|---|
| 测试 SSH 失败 | NAS sshd、密码、端口、frp；用户对 inbox 可写 |
| inbox 有 json 控制台没有 | consumer 没在 watch；`WECHAT_INGEST_ROOT` 不一致 |
| 控制台 401 | `.env` 密码；漏了 `CONSOLE_USER` / `CONSOLE_PASSWORD` 容器会拒启动 |
| 打开很卡 | 旧版本在全量扫 jsonl，换成现在的尾巴读取 + sqlite COUNT |
| 更早的消息点不了 | 需要带 `before_ts` 翻页的控制台（1.5.11+） |
| 语音点了没声 | 缺 silk-decoder，或容器没挂进去 |
| `[raw]` / 卡片消息 | dump 压缩 XML，不是坏语音；type 50 是通话，没有录音 |
| 切流量微信闪退 | 插件需 1.5.28+（SFTP 队列里重连，主线程不 close） |

---

## 12. 和 PKC / OpenClaw 的边界

- PKC 继续负责群触发回复。
- 本栈只记录。
- OpenClaw 若要读库，用 `skill/wechat-memory/SKILL.md` 调 `store/cli.py`，不要让模型去发私聊。
- 本仓库的 systemd **禁止**再拉起第二个 OpenClaw 进程。
