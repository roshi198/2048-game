# 2048 — Single Page Web Game

A polished, dependency-free implementation of the classic **2048** sliding puzzle,
built with plain HTML, CSS, and JavaScript. Ships with a one-command deploy script
and CI/CD for hosting on **AWS S3 + CloudFront**.

## Play locally

No build step required. Just open `index.html` in a browser, or serve the folder:

```bash
# any static server works, e.g.:
python3 -m http.server 8000
# then visit http://localhost:8000
```

**Controls**
- Desktop: **arrow keys** to move, **R** for a new game.
- Mobile/touch: **swipe** in any direction.

Your score and best score persist via `localStorage`, and the game resumes where
you left off on reload.

## Project structure

```
.
├── index.html                       # markup
├── style.css                        # styling + tile colors + animations
├── game.js                          # game logic (no dependencies)
├── deploy.sh                        # one-command deploy to AWS (pure AWS CLI)
├── .github/workflows/deploy.yml     # CI/CD: auto-deploy on push (OIDC)
└── infra/
    └── setup-github-oidc-role.sh    # creates the IAM role GitHub Actions uses
```

> **Note on CloudFormation:** this project deploys with **direct AWS CLI calls**,
> not CloudFormation. Some AWS accounts (e.g. those governed by an Organizations
> Service Control Policy) block `cloudformation:*`; the CLI approach needs only
> S3 and CloudFront permissions, so it works in those locked-down accounts too.

## Deploy to AWS (S3 + CloudFront)

### Architecture
- Content lives in a **private** S3 bucket (no public access, SSE enabled).
- **CloudFront** serves it globally over **HTTPS** with compression.
- **Origin Access Control (OAC)** ensures only the CloudFront distribution can
  read the bucket — the bucket itself stays fully locked down.

### Prerequisites
- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html),
  configured (`aws configure`), with **S3** and **CloudFront** permissions.
- `jq` (`brew install jq` / `apt-get install jq`).

### Deploy

```bash
./deploy.sh
```

Optional overrides via environment variables:

```bash
BUCKET=my-unique-2048-bucket REGION=us-east-1 ./deploy.sh
```

The script is **idempotent** (safe to re-run). It will:
1. Create a private, encrypted S3 bucket (if it doesn't exist).
2. Create an Origin Access Control and a CloudFront distribution (reused on re-runs).
3. Apply a bucket policy allowing only that distribution to read.
4. Upload `index.html`, `style.css`, and `game.js` with sensible cache headers.
5. Invalidate the CloudFront cache and print the live **HTTPS URL**.

> A brand-new CloudFront distribution takes ~5–15 minutes to fully propagate.
> Check status: `aws cloudfront get-distribution --id <ID> --query 'Distribution.Status' --output text` (want `Deployed`).

## Automated deploys with GitHub Actions (OIDC — no stored secrets)

Every push to `main` can auto-deploy to AWS. Authentication uses **OpenID Connect**:
GitHub mints a short-lived token for the workflow run, and AWS trusts it via an IAM
role. **No AWS access keys are ever stored in GitHub.**

### One-time setup

1. **Create the IAM role in AWS** (run once, from a machine with admin AWS access):

   ```bash
   GITHUB_ORG=roshi198 GITHUB_REPO=2048-game ./infra/setup-github-oidc-role.sh
   ```

   This creates the GitHub OIDC provider (if missing) and a role scoped to
   **only** this repo + the `main` branch, with S3 + CloudFront permissions.
   It prints the **Role ARN** at the end.

2. **Add the Role ARN as a repository variable** in GitHub:
   `Settings → Secrets and variables → Actions → Variables → New repository variable`
   - Name: `AWS_DEPLOY_ROLE_ARN`
   - Value: *(the ARN printed in step 1)*

That's it. Push to `main` (or use **Run workflow** on the Actions tab) and the game
deploys automatically. Change the region via the `env:` block in
`.github/workflows/deploy.yml`.

### Tear down

```bash
# 1. empty + delete the bucket (default name: game-2048-<ACCOUNT_ID>)
aws s3 rm "s3://game-2048-<ACCOUNT_ID>" --recursive
aws s3api delete-bucket --bucket "game-2048-<ACCOUNT_ID>"

# 2. disable then delete the CloudFront distribution (via the console is easiest),
#    or: aws cloudfront delete-distribution --id <ID> --if-match <ETag>
#    (a distribution must be disabled and fully deployed before it can be deleted)
```
