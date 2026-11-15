import React, { useEffect, useState } from 'react'
import {
  Button, Form, Input, InputNumber, Modal, Popconfirm, Select, Space, Switch, Table,
  Tag, Tooltip, Typography, message
} from 'antd'
import { CopyOutlined, DeleteOutlined, EditOutlined, PlusOutlined, SettingOutlined } from '@ant-design/icons'
import { api, whoami } from '../api'

const typeColor = {
  pypi: 'gold', npm: 'green', raw: 'blue', go: 'cyan', maven: 'geekblue',
  nuget: 'purple', rubygems: 'magenta', crates: 'volcano', conan: 'brown',
  pub: 'blue', hex: 'teal', hackage: 'cyan', cran: 'red',
  luarocks: 'lime', cocoapods: 'orange'
}

const TEMPLATES = [
  { value: 'tmpl-go', label: 'Go Modules (GOPROXY)', type: 'go', upstream: 'https://proxy.golang.org' },
  { value: 'tmpl-maven', label: 'Maven Central (Maven/Gradle/SBT)', type: 'maven', upstream: 'https://repo1.maven.org/maven2' },
  { value: 'tmpl-nuget', label: 'NuGet (.NET)', type: 'nuget', upstream: 'https://api.nuget.org' },
  { value: 'tmpl-rubygems', label: 'RubyGems', type: 'rubygems', upstream: 'https://rubygems.org' },
  { value: 'tmpl-crates', label: 'Rust Crates (sparse 索引)', type: 'crates', upstream: 'https://index.crates.io' },
  { value: 'tmpl-pypi', label: 'Python PyPI', type: 'pypi', upstream: 'https://pypi.org' },
  { value: 'tmpl-npm', label: 'Node npm', type: 'npm', upstream: 'https://registry.npmjs.org' },
  { value: 'tmpl-debian', label: 'Debian apt', type: 'raw', upstream: 'https://deb.debian.org' },
  { value: 'tmpl-alpine', label: 'Alpine apk', type: 'raw', upstream: 'https://dl-cdn.alpinelinux.org' },
  { value: 'tmpl-fedora', label: 'Fedora dnf', type: 'raw', upstream: 'https://dl.fedoraproject.org' },
  { value: 'tmpl-arch', label: 'Arch pacman', type: 'raw', upstream: 'https://geo.mirror.pkgbuild.com' },
  { value: 'tmpl-conan', label: 'Conan Center (C++)', type: 'conan', upstream: 'https://center.conan.io' },
  { value: 'tmpl-pub', label: 'Dart pub.dev', type: 'pub', upstream: 'https://pub.dev' },
  { value: 'tmpl-hex', label: 'Erlang/Elixir hex.pm', type: 'hex', upstream: 'https://repo.hex.pm' },
  { value: 'tmpl-hackage', label: 'Haskell Hackage', type: 'hackage', upstream: 'https://hackage.haskell.org' },
  { value: 'tmpl-cran', label: 'R CRAN', type: 'cran', upstream: 'https://cloud.r-project.org' },
  { value: 'tmpl-luarocks', label: 'Lua Rocks', type: 'luarocks', upstream: 'https://luarocks.org' },
  { value: 'tmpl-cocoapods', label: 'CocoaPods CDN', type: 'cocoapods', upstream: 'https://cdn.cocoapods.org' }
]

export default function Repos() {
  const [adm, setAdm] = React.useState(false)
  const [repos, setRepos] = useState([])
  const [latency, setLatency] = useState({})
  const [modal, setModal] = useState(null)
  const [snippetRepo, setSnippetRepo] = useState(null)
  const [form] = Form.useForm()

  const load = async () => setRepos(await api('/admin/repos'))

  useEffect(() => { load(); whoami().then((u) => setAdm(u?.role === 'admin')) }, [])

  useEffect(() => {
    if (!adm || !repos.length) return
    const probe = async () => {
      try {
        const { latency: l } = await api('/admin/ping')
        setLatency(l)
      } catch (err) {}
    }
    probe()
    const timer = setInterval(probe, 5000)
    return () => clearInterval(timer)
  }, [adm, repos.length])

  useEffect(() => {
    if (!form) return
    if (modal && modal !== 'add') {
      let backups = []
      try { backups = JSON.parse(modal.upstreams || '[]').slice(1) } catch (e) { backups = [] }
      form.setFieldsValue({
        name: modal.name,
        type: modal.type,
        upstream: modal.upstream,
        backup_upstreams: backups.join('\n'),
        quota_mb: modal.quota_mb || 0,
        enabled: !!modal.enabled,
        anonymous: !!modal.anonymous
      })
    } else if (modal === 'add') {
      form.resetFields()
    }
  }, [modal, form])

  const toggle = async (name, enabled) => {
    const r = repos.find((x) => x.name === name)
    if (!r) return
    setRepos(repos.map((x) => (x.name === name ? { ...x, enabled: enabled ? 1 : 0 } : x)))
    try {
      let upstreams = []
      try { upstreams = JSON.parse(r.upstreams || '[]') } catch (e) { upstreams = [] }
      if (!upstreams.length) upstreams = [r.upstream]
      await api(`/admin/repos/${name}`, {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          name,
          type: r.type,
          upstream: r.upstream,
          upstreams,
          quota_mb: r.quota_mb || 0,
          enabled,
          anonymous: !!r.anonymous
        })
      })
    } catch (err) {
      message.error('更新失败: ' + (err.message || ''))
      load()
    }
  }

  const save = async (values) => {
    try {
      const backups = String(values.backup_upstreams || '')
        .split('\n').map((x) => x.trim()).filter(Boolean)
      const payload = {
        name: values.name,
        type: values.type,
        upstream: values.upstream,
        upstreams: [values.upstream, ...backups],
        quota_mb: values.quota_mb || 0,
        enabled: !!values.enabled,
        anonymous: !!values.anonymous
      }
      if (modal === 'add') {
        await api('/admin/repos', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(payload)
        })
      } else {
        await api(`/admin/repos/${values.name}`, {
          method: 'PUT',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(payload)
        })
      }
      message.success('已保存')
      setModal(null)
      load()
    } catch (err) {
      message.error(err.message || '保存失败')
    }
  }

  const remove = async (name) => {
    await api(`/admin/repos/${name}`, { method: 'DELETE' })
    message.success('已删除')
    load()
  }

  const columns = [
    {
      title: '名称', dataIndex: 'name',
      render: (v, r) => (
        <span>
          <b>{v}</b>
          {r.anonymous ? <Tag color="green" style={{ marginLeft: 6 }}>匿名</Tag> : null}
        </span>
      )
    },
    {
      title: '类型', dataIndex: 'type',
      render: (v) => <Tag color={typeColor[v]}>{v}</Tag>
    },
    ...(adm ? [{
      title: '上游地址', dataIndex: 'upstream', ellipsis: true
    }, {
      title: '配额', dataIndex: 'quota_mb', width: 100,
      render: (v) => (v ? <Tag color="blue">{v} MB</Tag> : <Tag>不限</Tag>)
    }, {
      title: '延迟', dataIndex: 'latency', width: 96,
      render: (_, r) => {
        if (!(r.name in latency)) return <Tag> 测量中…</Tag>
        const ms = latency[r.name]
        if (ms < 0) return <Tag color="red">超时/故障</Tag>
        const color = ms < 300 ? 'green' : ms < 1200 ? 'orange' : 'red'
        return <Tag color={color}>{ms} ms</Tag>
      }
    }, {
      title: '启用', dataIndex: 'enabled',
      render: (v, r) => <Switch checked={!!v} onChange={(c) => toggle(r.name, c)} />
    }] : []),
    {
      title: '代理地址', dataIndex: 'name', width: 270,
      render: (v) => {
        const url = `${window.location.origin}/proxy/${v}/`
        return (
          <div style={{ display: 'flex', alignItems: 'center', gap: 4, minWidth: 0, width: '100%' }}>
            <code
              style={{
                fontSize: 12,
                minWidth: 0,
                wordBreak: 'break-all',
                lineHeight: 1.5
              }}
            >
              {url}
            </code>
            <Button
              type="text"
              size="small"
              icon={<CopyOutlined />}
              style={{ flexShrink: 0 }}
              onClick={async () => {
                try {
                  await navigator.clipboard.writeText(url)
                  message.success('代理地址已复制')
                } catch (err) {
                  message.warning('复制失败, 请手动复制')
                }
              }
              }
            />
          </div>
        )
      }
    },
    {
      title: '操作', dataIndex: 'action', width: adm ? 120 : 90,
      render: (_, r) => (
        <Space size={2}>
          <Tooltip title="客户端配置">
            <Button
              size="small"
              type={adm ? 'text' : 'primary'}
              icon={<SettingOutlined />}
              onClick={() => setSnippetRepo(r)}
            >
              {adm ? null : '配置'}
            </Button>
          </Tooltip>
          {adm && (
            <>
              <Tooltip title="编辑">
                <Button size="small" type="text" icon={<EditOutlined />} onClick={() => setModal(r)} />
              </Tooltip>
              <Popconfirm title="确认删除该仓库?" onConfirm={() => remove(r.name)}>
                <Tooltip title="删除">
                  <Button size="small" type="text" danger icon={<DeleteOutlined />} />
                </Tooltip>
              </Popconfirm>
            </>
          )}
        </Space>
      )
    }
  ]

  const snippetText = (repo) => {
    if (!repo) return ''
    const origin = window.location.origin
    const host = window.location.host
    const hostname = window.location.hostname
    const base = `${origin}/proxy/${repo.name}`
    const anon = !!repo.anonymous
    const token = '<API密钥>'
    // 需要鉴权时统一用 Basic 凭据: 用户名任意, 密码位置填 API 密钥
    const authBase = anon ? base : `${window.location.protocol}//<用户名>:${token}@${host}/proxy/${repo.name}`
    switch (repo.type) {
      case 'pypi': {
        // pip 会基于 index-url 拼出包文件的相对链接, 用 ?token= 时子请求会丢凭据, 因此用 Basic 认证
        const lines = [`pip config set global.index-url "${authBase}/simple/"`]
        if (window.location.protocol === 'http:') {
          lines.push(`pip config set global.trusted-host ${hostname}`)
        }
        return lines.join('\n')
      }
      case 'npm': {
        // npm 不支持在 registry 地址里带 query, 令牌必须写进 .npmrc 的 _authToken
        const lines = [`npm config set registry "${base}/"`]
        if (!anon) {
          lines.push(`npm config set //${host}/proxy/${repo.name}/:_authToken "${token}"`)
        }
        return lines.join('\n')
      }
      case 'go': {
        const lines = []
        if (!anon) {
          lines.push('# Go 在 HTTP 下拒绝携带账号密码, 请为本仓库开启「允许匿名下载」或改用 HTTPS 反向代理')
        }
        lines.push(`export GOPROXY="${authBase}"`)
        lines.push('export GOSUMDB=off')
        return lines.join('\n')
      }
      case 'maven': {
        const server = anon ? '' : `\n\n<server>\n  <id>modernmirror-${repo.name}</id>\n  <username>modernmirror</username>\n  <password>${token}</password>\n</server>`
        return `<!-- ~/.m2/settings.xml -->\n<mirror>\n  <id>modernmirror-${repo.name}</id>\n  <mirrorOf>*</mirrorOf>\n  <url>${base}/</url>\n</mirror>${server}`
      }
      case 'nuget': {
        const cred = anon ? '' : ` --username modernmirror --password "${token}" --store-password-in-clear-text`
        return `dotnet nuget add source "${base}/v3/index.json" -n ModernMirror${cred}`
      }
      case 'rubygems': {
        return [
          `bundle config mirror.https://rubygems.org "${authBase}"`,
          `gem sources --add "${authBase}/" --remove https://rubygems.org/`
        ].join('\n')
      }
      case 'crates': {
        const tokenBlock = anon ? '' : `\n\n[registries.modernmirror]\nindex = "sparse+${base}/"\ntoken = "${token}"`
        return `# ~/.cargo/config.toml\n[source.crates-io]\nreplace-with = "modernmirror"\n\n[source.modernmirror]\nregistry = "sparse+${base}/"${tokenBlock}`
      }
      case 'conan': {
        const lines = [`conan remote add modernmirror "${base}" --insecure`]
        if (!anon) {
          lines.push(`conan remote login modernmirror modernmirror -p "${token}"`)
        }
        return lines.join('\n')
      }
      case 'pub': {
        const lines = [`export PUB_HOSTED_URL="${base}"`]
        if (!anon) {
          lines.push(`dart pub token add "${origin}"`)
          lines.push('# 按提示粘贴 API 密钥; pub 的令牌按主机保存, 同一主机的所有仓库共用一个')
        }
        return lines.join('\n')
      }
      case 'hex': {
        return [
          'curl -o hex.pm.pem https://repo.hex.pm/public_key',
          `mix hex.repo add modernmirror "${authBase}" --public-key hex.pm.pem${anon ? '' : ` --auth-key "${token}"`}`
        ].join('\n')
      }
      case 'hackage': {
        return [
          `cabal config --set repository.modernmirror.url ${base}`,
          'cabal config --set repository.modernmirror.secure False',
          'cabal config --set repository.modernmirror.root-keys ""'
        ].join('\n')
      }
      case 'cran': {
        return `options(repos = c(CRAN = "${authBase}"))`
      }
      case 'luarocks': {
        return `luarocks --server="${authBase}" install <包名>`
      }
      case 'cocoapods': {
        const lines = []
        if (!anon) {
          lines.push('# CocoaPods 的 CDN 源不支持账号密码, 请为本仓库开启「允许匿名下载」')
        }
        lines.push('# Podfile')
        lines.push(`source '${base}/'`)
        return lines.join('\n')
      }
      default: {
        const lines = ['# 通用代理地址', base]
        if (!anon) {
          lines.push('# 需要鉴权时可在 URL 中带 Basic 凭据:')
          lines.push(authBase)
        }
        lines.push('', `curl -O "${authBase}/<文件路径>"`)
        return lines.join('\n')
      }
    }
  }

  const isEdit = !!modal && modal !== 'add'

  return (
    <>
      <div style={{ marginBottom: 16, display: 'flex', justifyContent: 'space-between' }}>
        <h2 style={{ margin: 0 }}>镜像仓库</h2>
        {adm && (
          <Button type="primary" icon={<PlusOutlined />} onClick={() => setModal('add')}>
            添加仓库
          </Button>
        )}
      </div>
      {!adm && (
        <Typography.Paragraph type="secondary" style={{ marginTop: -6 }}>
          这里只显示你有下载权限或允许匿名下载的仓库。点击「配置」获取对应客户端的接入命令；如需更多仓库，请联系管理员在用户组权限中授权。
        </Typography.Paragraph>
      )}
      <Table rowKey="id" dataSource={repos} columns={columns} />
      <Modal
        open={!!modal}
        title={modal === 'add' ? '添加仓库' : `编辑仓库: ${modal?.name || ''}`}
        onCancel={() => setModal(null)}
        footer={null}
        destroyOnClose
      >
        <Form
          form={form}
          initialValues={{ type: 'raw', enabled: true, anonymous: false }}
          layout="vertical"
          onFinish={save}
        >
          <Form.Item name="name" label="名称" rules={[{ required: true }]}>
            <Input disabled={modal !== 'add'} placeholder="如 upstream-maven" />
          </Form.Item>
          {!isEdit && (
            <Form.Item label="模板快速填充 (可选)" style={{ marginBottom: 4 }}>
              <Select
                allowClear
                placeholder="选择官方上游自动填充类型和地址"
                onChange={(v) => {
                  const t = TEMPLATES.find((x) => x.value === v)
                  if (t) {
                    form.setFieldsValue({ type: t.type, upstream: t.upstream, name: t.label.split(' ')[0].toLowerCase() })
                  }
                }}
                options={TEMPLATES}
              />
            </Form.Item>
          )}
          <Form.Item name="type" label="类型" rules={[{ required: true }]}>
            <Select
              options={[
                { value: 'pypi', label: 'PyPI (pip)' },
                { value: 'npm', label: 'npm' },
                { value: 'go', label: 'Go Modules (GOPROXY)' },
                { value: 'maven', label: 'Maven / Gradle / SBT' },
                { value: 'nuget', label: 'NuGet (.NET)' },
                { value: 'rubygems', label: 'RubyGems' },
                { value: 'crates', label: 'crates 静态文件' },
                { value: 'conan', label: 'Conan (C++)' },
                { value: 'pub', label: 'dart pub.dev' },
                { value: 'hex', label: 'hex.pm (Erlang)' },
                { value: 'hackage', label: 'Hackage (Haskell)' },
                { value: 'cran', label: 'CRAN (R)' },
                { value: 'luarocks', label: 'LuaRocks' },
                { value: 'cocoapods', label: 'CocoaPods' },
                { value: 'raw', label: '通用文件 (apt/yum 等)' }
              ]}
            />
          </Form.Item>
          <Form.Item name="upstream" label="主上游地址" rules={[{ required: true }]}>
            <Input placeholder="https://maven.aliyun.com/repository/public" />
          </Form.Item>
          <Form.Item name="backup_upstreams" label="备用上游地址 (每行一个, 按顺序故障转移)">
            <Input.TextArea rows={2} placeholder="https://mirror.example.com/maven2" />
          </Form.Item>
          <Form.Item name="quota_mb" label="缓存配额 (MB, 0 表示不限制)">
            <InputNumber min={0} step={1024} style={{ width: '100%' }} />
          </Form.Item>
          <Form.Item name="enabled" label="启用" valuePropName="checked">
            <Switch />
          </Form.Item>
          <Form.Item
            name="anonymous"
            label="允许匿名下载"
            valuePropName="checked"
            extra="开启后无需登录即可通过代理地址读取该仓库; Go、apt 等不方便携带凭据的客户端建议开启"
          >
            <Switch />
          </Form.Item>
          <Button type="primary" htmlType="submit" block>保存</Button>
        </Form>
      </Modal>

      <Modal
        open={!!snippetRepo}
        title={`客户端配置：${snippetRepo?.name || ''}`}
        onCancel={() => setSnippetRepo(null)}
        footer={[
          <Button key="copy" type="primary" icon={<CopyOutlined />} onClick={async () => {
            try {
              await navigator.clipboard.writeText(snippetText(snippetRepo))
              message.success('配置已复制')
            } catch (e) {
              message.warning('复制失败，请手动选择文本复制')
            }
          }}>复制配置</Button>,
          <Button key="close" onClick={() => setSnippetRepo(null)}>关闭</Button>
        ]}
        width={680}
      >
        <Typography.Paragraph type="secondary">
          {snippetRepo?.anonymous
            ? '该仓库已允许匿名下载，下面的配置不需要再填写密钥。'
            : '将 <API密钥> 替换为系统设置中生成的密钥；该密钥需具备当前仓库的下载权限。需要鉴权的地址中用户名可任意填写，密码位置填密钥即可。'}
        </Typography.Paragraph>
        <Input.TextArea value={snippetText(snippetRepo)} readOnly rows={8} style={{ fontFamily: 'monospace' }} />
      </Modal>
    </>
  )
}
