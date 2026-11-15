---
name: modernmirror-config
description: 将本机的 pip, npm, Go, Maven/Gradle, apt/yum 等软件源配置为指向用户自建的 ModernMirror 镜像缓存服务, 含备份与回滚; 也可协助管理员生成成员批量导入模板并执行导入。当用户要求把本机软件源切换到 ModernMirror、配置内部镜像源, 或批量导入成员时使用。
---

# ModernMirror 本机软件源配置

将用户设备上一个或多个包管理器的默认源切换为指向其自建的 ModernMirror 服务, 全程保留备份以便回滚。

服务端参数须向用户确认, 未知必须先询问:
- HOST: 服务地址, 如 192.168.1.10
- PORT: 服务端口, 默认 8800
- TOKEN: API 密钥, 在应用 Web 界面 系统设置 - API 密钥管理 中生成

通用代理地址: `http://$HOST:$PORT/proxy/<仓库名>/`, 其后的子路径原样转发到上游。

鉴权方式:
- 需要鉴权时优先用 Basic: `http://任意用户名:$TOKEN@$HOST:$PORT/proxy/<仓库名>/`
- 也支持请求头 `Session-Token: $TOKEN`、`X-Auth-Token: $TOKEN`、`Authorization: Bearer $TOKEN`
- 仓库开启「允许匿名下载」后无需携带 TOKEN
- `?token=$TOKEN` 只适合 curl 单次请求; 包管理器的子请求会丢失 query 或把 token 拼进路径, 不要使用

## 执行原则
1. 修改任何配置前, 先备份原文件为同目录 .bak-mm 后缀。
2. 一次只处理一个生态, 完成后立即执行该生态的验证命令。
3. TOKEN 只写入包管理器自身配置或用户 shell 环境文件, 不写入项目代码文件。
4. 请求 401/403 时提示检查密钥与用户组权限（注意:即使是管理员也要将自己添加到相应用户组）; 502 或哈希校验失败时建议查看应用审计日志。
5. 纯 HTTP 部署下 Go、CocoaPods 等无法携带凭据, 应引导用户为对应仓库开启「允许匿名下载」, 或改用 HTTPS 反向代理。

## 各生态操作

先确认镜像仓库页面已存在对应类型的仓库与正确上游。应用内「镜像仓库」页每行的「客户端配置」按钮会按类型生成可直接复制的命令, 优先采用它。

- **pip**: `pip config set global.index-url "http://任意用户名:$TOKEN@$HOST:$PORT/proxy/<仓库>/simple/"`; HTTP 部署再加 `global.trusted-host=$HOST`。索引里的包文件地址会被改写到代理, wheel/sdist 同样进入缓存。
- **npm**: registry 设为 `http://$HOST:$PORT/proxy/<仓库>/`, 再执行 `npm config set //$HOST:$PORT/proxy/<仓库>/:_authToken "$TOKEN"`; registry 地址不能带 query。
- **Go**: `export GOPROXY="http://$HOST:$PORT/proxy/<仓库>"`、`export GOSUMDB=off`; 必须使用匿名仓库。
- **Maven/Gradle**: `settings.xml` 的 mirror 指向代理, 同 id 的 `<server>` 填任意用户名与 TOKEN。
- **NuGet**: `dotnet nuget add source "http://$HOST:$PORT/proxy/<仓库>/v3/index.json" --username modernmirror --password "$TOKEN" --store-password-in-clear-text`; 上游用 `https://api.nuget.org`。
- **RubyGems**: `bundle config mirror.https://rubygems.org "http://任意用户名:$TOKEN@$HOST:$PORT/proxy/<仓库>"`, 或用 `gem sources` 替换。
- **Cargo**: `~/.cargo/config.toml` 用 `sparse+http://$HOST:$PORT/proxy/<仓库>/` 替换 `crates-io`, 需要时在 `[registries]` 下配 token; 上游用 `https://index.crates.io`。
- **Conan**: `conan remote add <名> "http://$HOST:$PORT/proxy/<仓库>" --insecure`, 再 `conan remote login` 写入凭据。
- **pub**: `export PUB_HOSTED_URL="http://$HOST:$PORT/proxy/<仓库>"`, 令牌用 `dart pub token add $HOST:$PORT`。
- **Hex**: `mix hex.repo add <名> "http://$HOST:$PORT/proxy/<仓库>" --public-key hex.pm.pem --auth-key "$TOKEN"`。
- **Hackage / CRAN / LuaRocks / CocoaPods / apt**: 按各自配置项把源地址指向代理; CocoaPods 在 HTTP 下必须使用匿名仓库。
- 回滚时恢复修改前的备份文件。

通用示例 - 验证代理可达:
`curl -u "x:$TOKEN" "http://$HOST:$PORT/proxy/<仓库名>/"`（匿名仓库可省略 `-u`）

## 成员批量导入

当管理员提供成员名单时, 可协助生成 ModernMirror 支持的模板文件并完成导入。

### 文件格式
支持 CSV / JSON / TOML / TXT, 模板可在应用内 用户组权限 -> 批量导入 中下载。

字段:
- username: 必填, 仅允许字母、数字、下划线、短横线, 长度 2 至 32 位。
- password: 可选; 留空时系统生成随机密码, 结果中只显示一次。
- role: 可选, user 或 admin, 缺省为 user; 使用 admin 前必须与用户确认。
- groups: 可选, 多个组用逗号分隔或数组表示; 留空时加入执行导入的当前组; 不存在的组会自动创建。

示例 CSV:
```
username,password,role,groups
alice,ChangeMe123,user,"devteam,qa"
bob,,user,devteam
```

### 生成与校验规则
1. 优先使用 CSV; 含逗号的多值字段必须使用双引号包裹。
2. 文件须为 UTF-8 编码, 且 CSV 首行为字段名。
3. 不要编造弱密码; 未提供初始密码时留空由系统生成, 并在导入后立即提示用户保存。
4. 不要将密码写入日志、截图或项目代码。

### 通过接口导入
1. 查询目标组 ID:
   `curl -s -H "X-Auth-Token: $TOKEN" "http://$HOST:$PORT/admin/groups"`
2. 上传文件:
   `curl -s -H "X-Auth-Token: $TOKEN" -F "file=@members.csv" "http://$HOST:$PORT/admin/groups/<组ID>/members/import"`
3. 将返回中的 created / added_to_group / errors 汇总给用户; 初始密码仅在 created 中返回一次。
4. 若返回 403, 确认 $TOKEN 属于管理员账号; 若 400, 按返回的中文原因修正文件后重试。

## 收尾
1. 列出本次全部被修改的文件与对应回滚命令, 供用户核对。
2. 提醒用户在 ModernMirror 的 缓存统计 页面确认命中率上升, 证明配置已生效。
