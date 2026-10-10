# Git Mirror Action

English | [简体中文](./README.zh-CN.md)

Mirror one repository to any number of destinations over SSH.

Pure PowerShell + `git`. No platform detection and API/Tokens calls.

## Usage

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

## Inputs

| Input         | Required | Description                                                                                                        |
| ------------- | -------- | ------------------------------------------------------------------------------------------------------------------ |
| `src_url`     | yes      | Source SSH URL, e.g. `git@github.com:owner/repo.git`.                                                              |
| `dst_url`     | yes      | Destination SSH URL(s). Separate multiple with commas, semicolons or newlines.                                     |
| `src_ssh_key` | no       | Private key with read access to the source. Defaults to `dst_ssh_key` when omitted.                                |
| `dst_ssh_key` | no       | Private key with write access to destinations. Defaults to `src_ssh_key` when omitted, or one key per destination. |
| `branches`    | no       | Branches to mirror. Empty for the source's default branch, `*` for every branch, or list names like `main, dev`.   |
| `tags`        | no       | Also mirror tags. On by default.                                                                                   |
| `force`       | no       | Force push so the destination matches the source. On by default; set `false` to fail instead of overwriting.       |

> At least one of `src_ssh_key` / `dst_ssh_key` must be non-empty.

## Behavior

1. Clone the source with `git clone --bare` into `$RUNNER_TEMP/git-mirror/`. On later runs the cache is reused and only an incremental `fetch --prune` runs.
2. `refs/pull/*` and `refs/merge-requests/*` are never mirrored, because most destination platforms reject them as hidden refs.
3. Destination repositories must already exist. No platform API is called, so nothing is created for you.

## License

[MIT](./LICENSE) © [abgox](https://me.abgox.com)
