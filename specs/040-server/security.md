# 040 · 安全、证书与令牌

2026-11-27 · 自建服务的 TLS、自签名证书、设备令牌、secret bundle 与恢复。产品要求见[规格](spec.md)，备份范围见[元数据备份](metadata-backup.md)，协议见[协议](protocol.md)。

## 1. 威胁模型与原则

**假设。** 单用户、自托管、局域网为主；不依赖公共 CA；服务器可能暴露到 WAN；PostgreSQL 和 S3 可能是外部服务；客户端是 Apple Silicon Mac。

**要防的：**

- 未授权设备访问 gRPC 或 S3；
- 中间人伪造服务器／RustFS；
- 令牌、私钥、S3 凭据泄漏到日志、备份、URL；
- 过期证书、指纹变化、撤销设备仍能写入；
- 备份被窃取后可读；
- 恢复时把旧状态或错误身份当成有效。

**原则：**

- TLS 必须验证，不因自签名而关闭校验。
- 客户端固定服务器身份；证书变化必须显式确认。
- 令牌只存哈希；私钥只进加密 secret bundle。
- 备份静态加密；TLS 不等于静态加密。
- 最小权限：S3 服务账号、gRPC 设备角色、admin 单独角色。
- 公开暴露必须显式配置；默认只监听局域网。

## 2. 证书方案

### 2.1 推荐：私有 CA + 服务器 leaf

```text
RawMaster Private CA（自签名根，离线保存）
  ├─ Server leaf：gRPC hostname / IP
  ├─ RustFS leaf：S3 endpoint hostname / IP（可选，由同一 CA 签发）
  └─ 其他内部服务 leaf
```

- 根 CA 自签名即可，不需要公共 CA；客户端固定 CA 公钥／指纹。
- leaf 轮换不影响客户端信任；只要仍是同一 CA。
- CA 私钥离线或放在独立 secret manager；服务器只持 leaf 私钥。
- leaf SAN 包含实际 DNS 名、`.local`、IP；presigned URL 的 host 必须匹配。
- 有效期：CA 10 年；leaf 1–2 年；到期前轮换。
- 证书链和 SPKI 指纹进入元数据备份；私钥进 secret bundle。

### 2.2 简化：单张自签名证书

- 适合单服务器、单 endpoint、手工管理。
- 客户端固定证书 SPKI；证书续期／换主机名会导致指纹变化，需要重新确认。
- 私钥仍进 secret bundle；不能因为“自签名”就把私钥放普通备份。
- 如果同时有 gRPC 和 RustFS，建议至少两张证书或一个私有 CA，避免共享私钥。

### 2.3 客户端信任

- macOS 钥匙串安装私有 CA，或在应用内用自定义 `URLSessionDelegate`／SwiftNIO trust roots 验证。
- gRPC Swift 2 使用 `GRPCNIOTransportHTTP2` + TLS；配置 trust roots、hostname verification；不要使用 `.plaintext`。
- S3 直传使用 URLSession／AWS SDK for Swift／Soto；自定义 endpoint 和 trust；presigned URL host 与证书 SAN 一致。
- 不能全局关闭 ATS 或 TLS 校验；只对明确的自建 endpoint 使用固定 CA。
- 固定 SPKI 而不是只固定 leaf 证书，允许同 key 续期；轮换 key 时显式重新确认。

### 2.4 证书轮换

1. 用同一 CA 签发新 leaf；部署到 Server／RustFS。
2. 旧 leaf 保留重叠期；客户端信任 CA 时无感。
3. 更新 `server_identity` 和 secret bundle 引用；记录审计。
4. 撤销旧 leaf；确认无客户端仍在使用。
5. 如果 CA 轮换：客户端需要重新固定；提供导出新 CA 指纹的明确流程。

### 2.5 证书恢复

- 元数据备份恢复公有证书链、SPKI、SAN、有效期。
- secret bundle 恢复 CA 私钥、leaf 私钥。
- 两者都恢复：客户端固定不变，直接连接。
- 只有证书、无私钥：不能完成 TLS；重新签发并重新固定。
- 证书过期：用同一 CA 重签；单证书模式重新固定。
- 主机名变化：新 leaf 包含新 SAN；客户端信任 CA 时无感。

## 3. 设备令牌

### 3.1 模型

- 登记码一次性、短 TTL（10 分钟）；管理员生成。
- 登记成功签发 256-bit 随机不透明令牌；客户端存钥匙串。
- 数据库只存 `token_hash`（SHA-256 或 HMAC-SHA-256）和 `token_key_id`；不存明文。
- 令牌可撤销、轮换；设备记录保留。
- 可选 pepper：HMAC 密钥进 secret bundle；丢失则所有令牌失效，需要重新登记。
- 更简单的 V1：无 pepper 的 SHA-256 哈希；数据库泄漏不能反推令牌；secret bundle 只需证书私钥和 S3 凭据。

### 3.2 传输与生命周期

- 令牌只通过 TLS 传输；不放在 URL、日志、错误消息、presigned URL。
- 每个 gRPC 请求带 `authorization: Bearer`；服务器校验哈希、设备状态、库所有权。
- 令牌轮换：新令牌生效后旧令牌短重叠期；撤销立即生效。
- 设备丢失：撤销令牌；可选远程清除本地缓存（后续）。
- 恢复：令牌哈希随元数据备份；pepper／HMAC key 随 secret bundle；恢复后原设备令牌继续有效。

### 3.3 备份边界

| 数据 | 入元数据备份 | 入 secret bundle |
| --- | --- | --- |
| 设备记录、角色、撤销状态 | 是 | 否 |
| 令牌哈希、key ID | 是 | 否 |
| 明文令牌 | 否（不存储） | 否 |
| pepper／HMAC key | 否 | 是 |
| 登记码 | 否（瞬态） | 否 |

**“令牌本身属于备份范畴”** 的落地方式是：令牌记录和哈希入元数据备份；能验证令牌的密钥入 secret bundle；明文令牌从不落库，因此不能也不应备份。

## 4. secret bundle

### 4.1 内容

- CA 私钥；Server leaf 私钥；RustFS leaf 私钥（若由 RAWMaster 管理）。
- 令牌 pepper／HMAC key。
- S3 服务账号凭据（若未用外部密钥管理）。
- 备份加密密钥的 key ID／引用；实际解密密钥离线保存，不放在同一 secret bundle 和同一存储位置。
- 其他内部服务凭据。

### 4.2 格式与加密

- 单独文件／对象：`secrets/<generationID>.age` 或等价加密容器。
- 使用 age／OpenPGP／libsodium secretbox；密钥离线或由管理员保管。
- 加密后再上传 S3；S3 SSE 作为叠加，不替代客户端加密。
- 不与元数据 dump 同目录、同权限；访问需要 admin + 解密密钥。
- 记录 `secret_ref`、key ID、创建时间、轮换时间；不记录明文。
- 备份加密密钥不能与备份同址；至少离线保存一份。

### 4.3 恢复

- 先恢复元数据，再恢复 secret bundle；两者都通过校验才启动 TLS。
- secret bundle 缺失／解密失败：停止恢复，明确要求重新签发证书、重新登记设备。
- 不允许回退到明文私钥或关闭 TLS。
- 恢复后审计：证书序列、SPKI、令牌 key ID、S3 凭据版本。

## 5. 传输与存储加密

| 通道／位置 | 方案 |
| --- | --- |
| gRPC | TLS 1.2+（优先 1.3），私有 CA／自签名，客户端固定 |
| S3 Direct | HTTPS，RustFS／云 S3 证书；客户端信任／固定；失败 Relay |
| Relay | gRPC TLS；Server 到 S3 的 HTTPS |
| PostgreSQL | TLS（如跨主机）；本地／内网也建议 |
| S3 静态 | SSE／bucket 加密；RAWMaster 不依赖其作为唯一保护 |
| 元数据备份 | 客户端加密 secret bundle；dump 可额外加密；S3 SSE |
| 本地磁盘 | 仅日志／临时；磁盘加密由 OS／TrueNAS 负责；临时文件及时清理 |

**自签名证书只解决传输身份与加密，不解决备份静态加密。** 备份必须另行加密。

## 6. S3 自签名证书与 Direct／Relay

- RustFS 使用私有 CA leaf；客户端信任 CA 后 Direct 可用。
- presigned URL 的 host 必须是证书 SAN；否则 TLS 失败。
- 客户端不能信任 RustFS 证书时，Direct 失败自动 Relay；Relay 只信任 Server。
- 不把 RustFS 根凭据给客户端；Server 用受限服务账号生成 presigned URL。
- 不给 presigned URL 配置过长 TTL；5–15 分钟。
- presigned URL 只允许精确 key、方法、part 号；不记日志。
- 云 S3 用系统信任或固定 CA；RustFS 用私有 CA；MinIO 同理。

## 7. 访问控制

- 单所有者；设备角色：owner、reader（可选）、admin（本机 CLI）。
- gRPC 方法级授权：库写、库读、上传、备份、恢复、证书轮换。
- S3 服务账号只允许 `libraries/*` 前缀的 GET/PUT/HEAD/ListMultipart；不给删除整个 bucket。
- 备份／恢复方法只允许 admin；建议本机 CLI 或 mTLS 管理通道。
- 公开暴露：TLS、防火墙、速率限制、失败审计、禁用匿名 S3。
- 日志脱敏：令牌、私钥、S3 secret、presigned query、备份密钥。

## 8. 审计

记录：

- 设备登记、撤销、令牌轮换；
- 证书签发、轮换、指纹确认、失败握手；
- 库所有权获取／转移；
- 上传创建、Direct／Relay 模式、校验失败；
- 元数据备份、验证、恢复、doctor；
- secret bundle 创建／解密／轮换；
- 权限拒绝、TLS 失败、配额超限。

不记录：明文令牌、私钥、S3 secret、presigned 完整 URL、备份解密密钥。

## 9. 验收

1. 私有 CA + leaf：客户端固定 CA；错误 CA／主机名／过期证书被拒；同 CA 轮换 leaf 无感。
2. 单自签名证书：SPKI 固定；证书变化阻止写入并要求确认。
3. 设备令牌：登记、撤销、轮换、错误令牌、过期令牌；哈希库中不可反推明文。
4. secret bundle：加密、错误密钥拒绝、缺失时停止启动、恢复后证书和令牌有效。
5. 备份：元数据 dump 不含私钥／明文令牌；secret bundle 单独加密；S3 SSE；日志无密钥。
6. S3 直传：RustFS 自签名证书信任；不受信任时 Relay；presigned URL host／SAN 不匹配被拒。
7. 恢复：同 CA／私钥恢复后客户端无需重新固定；只有元数据、无私钥时要求重新签发／登记。
8. 公开暴露：默认局域网；未配置 TLS 时拒绝公开；速率限制和失败审计生效。
9. 审计：证书、令牌、备份、恢复事件可查；无敏感值。
10. 恢复演练：从元数据 + secret bundle 恢复到隔离服务器，客户端重新连接并通过 gRPC／S3 校验。

## 10. 待决

| 编号 | 问题 | 建议 |
| --- | --- | --- |
| S-01 | 私有 CA 还是单证书 | 私有 CA + leaf；单证书简化模式 |
| S-02 | 令牌 pepper | V1 可先无 pepper 的 SHA-256；需要更强保护时加 HMAC + secret bundle |
| S-03 | secret bundle 加密 | age 或 libsodium；密钥离线；S3 SSE 叠加 |
| S-04 | S3 客户端信任 | 私有 CA 装入钥匙串或应用内 trust；失败 Relay |
| S-05 | CA 轮换 | 显式重新固定；提供导出指纹和重叠期 |
| S-06 | 管理通道 | 本机 CLI 或 mTLS；公网不暴露 admin |
| S-07 | 审计保留 | 90 天起；与元数据备份分开 |
| S-08 | 设备远程擦除 | 后续；V1 只撤销令牌 |
