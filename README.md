# WeChatIngest

iOS 微信静默采集 + NAS 知识库。和 PKC 并存：PKC 继续负责群里触发回复，本插件只记录、**永不回复私聊**。

```text
微信 (TrollFools 注入 dylib)
    --SFTP-->  NAS 待入库/
    --watch-->  群聊|私聊 jsonl + sqlite
    --只读-->  网页控制台 :18791
```

## 文档

| 文件 | 给谁 |
|---|---|
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | 脱密开发文档，可公开、可丢给别的 AI |
| [docs/DEPLOY-FNOS.md](docs/DEPLOY-FNOS.md) | 脱密部署教程，重点是飞牛 / Docker / systemd |
| [docs/install-quanqian.md](docs/install-quanqian.md) | 全能签注入 |
| [docs/install-trollfools.md](docs/install-trollfools.md) | TrollFools 注入 |

操作者自己的主机、账号、路径写在本机 `docs/DEV-INTERNAL.md`，**不进 git**。

## 手机插件

```bash
bash scripts/build-dylib.sh
# build/WeChatIngest.dylib
# build/WeChatIngest-<版本>.dylib
```

arm64，adhoc 签名，注入 `com.tencent.xin`。入口：**我 → 插件 → 微信记忆**。

## NAS

```bash
export WECHAT_INGEST_ROOT=/path/to/data
bash deploy/install-user.sh
# 或 systemd Type=simple: python3 store/consumer.py --watch
```

控制台：

```bash
cd console
cp .env.example .env   # 填用户名密码
docker compose up -d --build
```

## 硬规则

- 不自动回私聊
- 未知消息类型存 `raw`，不丢
- 控制台只读
- 不要把 `.env`、聊天记录、爱思包、微信 IPA 推进仓库

## 许可

个人工具，无担保。第三方代码（libssh2、mbedtls）遵循各自许可证，预编译头和库在 `third_party/ios-arm64/`。
