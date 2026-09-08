# Contributing

## GitHub account

Use the existing authorized GitHub identity **`abdulmohsenssda`** for work in
the deployment, backend, and frontend repositories. Use the same identity when
working on existing pull-request branches; do not substitute
`almaabd16_bhgithub`.

Before pushing or opening a pull request, verify the active account without
printing or sharing credentials:

```bash
gh auth status --hostname github.com
gh auth list --hostname github.com
```

These commands must not be run with options that display a token. Do not paste
their output into issues, pull requests, logs, or chat if it contains account
details beyond what is needed for verification.

Switch explicitly when necessary:

```bash
gh auth switch --hostname github.com --user abdulmohsenssda
```

Never commit or upload tokens, passwords, SSH private keys, `.env` files,
credential stores, or other authentication files.

## Default branch baseline

Every change must start from the current default branch of the repository it
modifies. Never use a stale worktree, an old pull-request head, or another
feature branch as the integration baseline.

| Repository | Default branch |
| --- | --- |
| `abdul-mohsen/deployment` | `main` |
| `abdul-mohsen/ifritah-go` | `dev` |
| `abdul-mohsen/go_ifritah` | `dev` |

Before creating a worktree or integration branch, refresh the matching remote
default branch and verify its head:

```bash
gh repo view OWNER/REPO --json defaultBranchRef
git fetch github DEFAULT_BRANCH
git switch --create WORK_BRANCH github/DEFAULT_BRANCH
git merge-base --is-ancestor github/DEFAULT_BRANCH HEAD
```

Replace `OWNER/REPO`, `DEFAULT_BRANCH`, and `WORK_BRANCH` with the values for
the repository being changed. If the ancestry check fails, stop and recreate
the worktree from the current default branch before cherry-picking approved
commits. For a multi-repository change, establish this baseline independently
in each repository; do not use the deployment branch as the backend or
frontend baseline.

## Access and branch protection

- If the account has read-only access, do not work around it with another
  account. Prepare the change locally, record the commit SHA, and ask an
  authorized maintainer to grant access or cherry-pick the commit.
- If branch protection rejects a push, do not force-push or bypass the rule.
  Keep the commit, use the repository's required pull-request flow, and ask a
  maintainer when an approval, status check, or protected-branch exception is
  required.
