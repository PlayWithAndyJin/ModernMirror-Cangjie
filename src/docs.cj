package modernmirror

import std.collection.*
import stdx.encoding.json.*

let API_ENDPOINTS = [
    ("GET", "/api/health", "健康检查"),
    ("GET", "/api/whoami", "当前登录身份"),
    ("POST", "/auth/login", "账号密码登录"),
    ("POST", "/auth/verify-totp", "校验动态码完成登录"),
    ("POST", "/auth/logout", "退出登录"),
    ("GET", "/auth/me", "当前用户信息"),
    ("POST", "/auth/password", "修改密码"),
    ("POST", "/auth/mfa/setup", "生成 MFA 密钥"),
    ("POST", "/auth/mfa/enable", "确认开启 MFA"),
    ("POST", "/auth/mfa/disable", "关闭 MFA"),
    ("GET", "/auth/tokens", "列出 API 密钥"),
    ("POST", "/auth/tokens", "创建 API 密钥"),
    ("POST", "/auth/tokens/revoke", "吊销 API 密钥"),
    ("POST", "/auth/tokens/revoke-legacy", "吊销旧版 API 密钥"),
    ("GET", "/admin/users", "用户列表"),
    ("POST", "/admin/users", "新增用户"),
    ("PUT", "/admin/users/{username}", "修改用户"),
    ("DELETE", "/admin/users/{username}", "删除用户"),
    ("POST", "/admin/users/{username}/reset-mfa", "重置用户 MFA"),
    ("GET", "/admin/groups", "用户组列表"),
    ("POST", "/admin/groups", "新增用户组"),
    ("PUT", "/admin/groups/{gid}", "修改用户组"),
    ("DELETE", "/admin/groups/{gid}", "删除用户组"),
    ("POST", "/admin/groups/{gid}/members", "加入组成员"),
    ("DELETE", "/admin/groups/{gid}/members/{username}", "移除组成员"),
    ("POST", "/admin/groups/{gid}/members/import", "批量导入成员"),
    ("POST", "/admin/groups/{gid}/repos/{repo}", "授予仓库权限"),
    ("DELETE", "/admin/groups/{gid}/repos/{repo}", "撤销仓库权限"),
    ("GET", "/admin/repos", "仓库列表"),
    ("POST", "/admin/repos", "新增仓库"),
    ("PUT", "/admin/repos/{name}", "修改仓库"),
    ("DELETE", "/admin/repos/{name}", "删除仓库"),
    ("GET", "/admin/ping", "上游连通性探测"),
    ("GET", "/admin/stats", "缓存统计"),
    ("POST", "/admin/cache/cleanup", "清理缓存"),
    ("GET", "/admin/packages", "私有包列表"),
    ("POST", "/admin/packages/{repo}", "上传私有包"),
    ("DELETE", "/admin/packages/{repo}/{filename}", "删除私有包"),
    ("GET", "/admin/audit", "审计日志"),
    ("GET", "/admin/security/status", "安全状态"),
    ("POST", "/admin/security/reset-passwords", "重置全部密码"),
    ("GET", "/admin/settings", "读取设置"),
    ("PUT", "/admin/settings", "更新设置"),
    ("GET", "/proxy/{repo}/{path}", "代理下载"),
    ("HEAD", "/proxy/{repo}/{path}", "代理元信息"),
    ("GET", "/pkg/{repo}/{filename}", "下载私有包"),
    ("GET", "/simple/{repo}", "私有包索引")
]

func buildOpenApi(): JsonObject {
    let root = jObj()
    root.put("openapi", jStr("3.1.0"))
    let info = jObj()
    info.put("title", jStr(APP_NAME))
    info.put("version", jStr(APP_VERSION))
    root.put("info", info)
    let paths = jObj()
    for (item in API_ENDPOINTS) {
        let method = item[0]
        let routePath = item[1]
        let summary = item[2]
        let pathItem = match (paths.get(routePath)) {
            case Some(v) => v.asObject()
            case None =>
                let obj = jObj()
                paths.put(routePath, obj)
                obj
        }
        let operation = jObj()
        operation.put("summary", jStr(summary))
        let responses = jObj()
        let ok = jObj()
        ok.put("description", jStr("成功"))
        responses.put("200", ok)
        operation.put("responses", responses)
        pathItem.put(method.toAsciiLower(), operation)
    }
    root.put("paths", paths)
    return root
}

func redocHtml(): String {
    let sb = StringBuilder()
    sb.append("<!doctype html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\">")
    sb.append("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">")
    sb.append("<title>" + APP_NAME + " 接口文档 ReDoc</title>")
    sb.append("<style>body{margin:0;padding:0}</style></head><body>")
    sb.append("<redoc spec-url=\"/openapi.json\"></redoc>")
    sb.append("<script src=\"https://cdn.jsdelivr.net/npm/redoc@next/bundles/redoc.standalone.js\"></script>")
    sb.append("</body></html>")
    return sb.toString()
}

func docsHtml(): String {
    let sb = StringBuilder()
    sb.append("<!doctype html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\">")
    sb.append("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">")
    sb.append("<title>" + APP_NAME + " 接口文档</title>")
    sb.append("<style>body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;")
    sb.append("margin:0;background:#0f172a;color:#dbe6ff}main{max-width:960px;margin:0 auto;padding:32px}")
    sb.append("h1{font-size:24px}table{width:100%;border-collapse:collapse;margin-top:16px}")
    sb.append("th,td{text-align:left;padding:10px 12px;border-bottom:1px solid #1e293b;font-size:14px}")
    sb.append("th{color:#93c5fd;font-weight:600}code{background:#1e293b;padding:2px 6px;border-radius:4px}")
    sb.append(".m{display:inline-block;min-width:52px;color:#34d399;font-weight:600}")
    sb.append("p{color:#94a3b8;font-size:14px}</style></head><body><main>")
    sb.append("<h1>" + APP_NAME + " 接口文档</h1>")
    sb.append("<p>版本 " + APP_VERSION + "。所有管理接口使用 Session-Token 请求头认证。")
    sb.append("完整机器可读描述见 <code>/openapi.json</code>。</p>")
    sb.append("<table><thead><tr><th>方法</th><th>路径</th><th>说明</th></tr></thead><tbody>")
    for (item in API_ENDPOINTS) {
        sb.append("<tr><td><span class=\"m\">" + htmlEscape(item[0]) + "</span></td>")
        sb.append("<td><code>" + htmlEscape(item[1]) + "</code></td>")
        sb.append("<td>" + htmlEscape(item[2]) + "</td></tr>")
    }
    sb.append("</tbody></table></main></body></html>")
    return sb.toString()
}
