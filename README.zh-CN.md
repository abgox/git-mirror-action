# Git Mirror Action

[English](./README.md) | 简体中文

通过 SSH 把一个仓库镜像到任意多个目标平台。

纯 PowerShell + `git`，无平台识别和 API/TOKEN 调用

## 用法

```yaml
jobs:
  git-mirror:
    name: Git Mirror
    runs-on: ubuntu-latest
    steps:
      - uses: abgox/git-mirror-action@main
        with:
          src_url: git@github.com:${{ github.repository }}.git
          dst_url: |
            - git@atomgit.com:${{ github.repository }}.git
            - git@gitee.com:${{ github.repository }}.git
          src_ssh_key: ${{ secrets.SSH_PRIVATE_KEY_GITHUB }}
          dst_ssh_key: |
            - ${{ secrets.SSH_PRIVATE_KEY_ATOMGIT }}
            - ${{ secrets.SSH_PRIVATE_KEY_GITEE }}
```

## 参数

| 参数          | 必填 | 说明                                                                        |
| ------------- | ---- | --------------------------------------------------------------------------- |
| `src_url`     | 是   | 源 SSH 地址，如 `git@github.com:owner/repo.git`                             |
| `dst_url`     | 是   | 目标 SSH 地址，多个地址用逗号、分号或换行分隔                               |
| `src_ssh_key` | 否   | 具有读权限的私钥，留空时回退到 `dst_ssh_key`                                |
| `dst_ssh_key` | 否   | 具有写权限的私钥，留空时回退到 `src_ssh_key`；也可按目的端数量逐个配置      |
| `branches`    | 否   | 镜像哪些分支。留空为源的默认分支，`*` 为全部分支，也可指定，如 `main, dev`  |
| `tags`        | 否   | 是否镜像 tag，默认开启                                                      |
| `force`       | 否   | 强制推送，使目的端与源端保持一致，默认开启；设为 `false` 则遇到偏离直接失败 |

> `src_ssh_key` / `dst_ssh_key` 至少要有一个非空。

## 行为

1. 用 `git clone --bare` 把源克隆到 `$RUNNER_TEMP/git-mirror/`，后续运行复用缓存，只做增量 `fetch --prune`。
2. `refs/pull/*`、`refs/merge-requests/*` 这类引用不会镜像，因为多数目的平台会以 hidden ref 为由拒绝。
3. 目的仓库必须预先建好，不调任何平台 API，因此不会自动创建仓库。

## License

[MIT](./LICENSE) © [abgox](https://me.abgox.com)
