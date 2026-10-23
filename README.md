# 2048 — Single Page Web Game

A polished, dependency-free implementation of the classic **2048** sliding puzzle,
built with plain HTML, CSS, and JavaScript. Ships with infrastructure-as-code and a
deploy script for hosting on **AWS S3 + CloudFront**.

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
├── index.html                      # markup
├── style.css                       # styling + tile colors + animations
├── game.js                         # game logic (no dependencies)
├── deploy.sh                       # one-command deploy to AWS
├── .github/workflows/deploy.yml    # CI/CD: auto-deploy on push (OIDC)
└── infra/
    ├── cloudformation.yaml         # S3 (private) + CloudFront + OAC + HTTPS
    └── github-oidc-role.yaml       # IAM role GitHub Actions assumes (no secrets)
```

## Deploy to AWS (S3 + CloudFront)

### Architecture
- Content lives in a **private** S3 bucket (no public access).
- **CloudFront** serves it globally over **HTTPS** with compression.
- **Origin Access Control (OAC)** ensures only CloudFront can read the bucket —
  the bucket itself stays locked down.

### Prerequisites
- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
  installed and configured (`aws configure`).
- IAM permissions for CloudFormation, S3, and CloudFront.

### Deploy

```bash
./deploy.sh
```

Optional overrides via environment variables:

```bash
STACK_NAME=my-2048 REGION=us-east-1 ./deploy.sh
```

The script will:
1. Create/update the CloudFormation stack (`infra/cloudformation.yaml`).
2. Upload `index.html`, `style.css`, and `game.js` with sensible cache headers.
3. Invalidate the CloudFront cache so updates appear immediately.
4. Print the live **HTTPS URL**.

> First-time CloudFront distributions take ~5–15 minutes to fully propagate.

## Automated deploys with GitHub Actions (OIDC — no stored secrets)

Every push to `main` can auto-deploy to AWS. Authentication uses **OpenID Connect**:
GitHub mints a short-lived token for the workflow run, and AWS trusts it via an IAM
role. **No AWS access keys are ever stored in GitHub.**

### One-time setup

1. **Create the IAM role in AWS** (run once, from a machine with admin AWS access):

   ```bash
   aws cloudformation deploy \
     --stack-name game-2048-gha-role \
     --template-file infra/github-oidc-role.yaml \
     --capabilities CAPABILITY_NAMED_IAM \
     --region us-east-1 \
     --parameter-overrides \
       GitHubOrg=YOUR_GITHUB_ORG \
       GitHubRepo=YOUR_REPO_NAME \
       GitHubBranch=main
   ```

   > If your AWS account **already has** a GitHub OIDC provider, add
   > `CreateOIDCProvider=false` to the parameters (an account allows only one).

2. **Grab the role ARN** from the stack output:

   ```bash
   aws cloudformation describe-stacks \
     --stack-name game-2048-gha-role \
     --region us-east-1 \
     --query "Stacks[0].Outputs[?OutputKey=='RoleArn'].OutputValue" --output text
   ```

3. **Add it as a repository variable** in GitHub:
   `Settings → Secrets and variables → Actions → Variables → New repository variable`
   - Name: `AWS_DEPLOY_ROLE_ARN`
   - Value: *(the ARN from step 2)*

That's it. Push to `main` (or use **Run workflow** on the Actions tab) and the game
deploys automatically. The workflow region/stack default to `us-east-1` /
`game-2048` — edit the `env:` block in `.github/workflows/deploy.yml` to change them.

### Tear down

```bash
# empty the bucket first (its name is in the stack outputs), then:
aws cloudformation delete-stack --stack-name game-2048 --region us-east-1
```

> The bucket uses `DeletionPolicy: Retain`, so you must empty and delete it
> manually if you want it fully removed.
