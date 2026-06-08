# Production Deploy Bootstrap

One-time setup required before the `Deploy Production Infrastructure and Backend`
workflow (`.github/workflows/deploy.yml`) can run green. Do these in order.

## 1. AWS resources (run the script)

Run with admin-ish AWS credentials (your own, **not** the deploy role it creates):

```bash
cd prod
./bootstrap.sh
```

This creates / verifies, idempotently:
- S3 state bucket `eqaya-infra-tf-state` (versioning + encryption + public-access-block)
- DynamoDB lock table `eqaya-tf-locks` (required by the backend before `init`)
- GitHub OIDC provider in IAM
- IAM deploy role `eqaya-prod-github-deploy` (trust scoped to
  `repo:Eqaya/eqaya_infra:environment:production`)

It prints the role ARN at the end — you need it in step 3.

## 2. GitHub `production` environment + approval gate

The deploy job uses `environment: production` and runs `terraform apply -auto-approve`.
Add a **required reviewer** so prod applies pause for human approval:

```bash
# Create the environment with you as a required reviewer
gh api -X PUT "repos/Eqaya/eqaya_infra/environments/production" \
  -f "reviewers[][type=User][id]=$(gh api users/<your-github-username> --jq .id)"
```

Or via the UI: Settings → Environments → New environment → `production` →
Required reviewers → add yourself/the ops team.

> Without this, **every push to `release` deploys to prod unattended.**

## 3. GitHub secrets

```bash
# OIDC deploy role ARN from step 1
gh secret set AWS_ROLE_TO_ASSUME -R Eqaya/eqaya_infra \
  -b "arn:aws:iam::026108250515:role/eqaya-prod-github-deploy"

# Token to check out the private app repo (PAT with `repo` read scope, or a
# fine-grained token with Contents:read on Eqaya/eqaya-platform)
gh secret set APP_REPO_TOKEN -R Eqaya/eqaya_infra -b "<github_pat>"

# App runtime secrets. Every key here is injected into the container as its
# own env var (the task def maps `for name in keys(app_secrets)`), read from
# the `eqaya-prod-app-config` Secrets Manager secret.
#
# VERIFIED against the backend (src/config/validateEnv.js): production HARD-
# requires only 5 vars, and Terraform already injects ALL of them
# (FRONTEND_URL, DATABASE_URL, JWT_SECRET, AWS_REGION, AWS_S3_BUCKET). So the
# app BOOTS GREEN with an empty PROD_APP_SECRETS_JSON. Everything below is
# feature-gated — only needed when that feature is exercised — so add keys
# incrementally ("deploy small").
#
# Email (SES) — the app uses the ECS TASK ROLE for SES (it already has
# ses:SendEmail on identity/${domain}). Do NOT set AWS_ACCESS_KEY_ID /
# AWS_SECRET_NAME / AWS_SSM_PARAMETER_NAME in prod — any of those makes
# EmailService try static creds instead of the role. Email needs only:
#   AWS_SES_ENABLED   = "true"                  (turns SES on)
#   AWS_SES_FROM_EMAIL = "info@eqaya.com"       (a VERIFIED @eqaya.com identity)
#
# Other common feature keys the backend reads (set only what you use):
#   STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET   (card payments)
#   OPENAI_API_KEY / GEMINI_API_KEY / AI_MODEL (AI milestone + property check)
#   GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, GOOGLE_REDIRECT_URI  (Google OAuth)
#   GOOGLE_MAPS_API_KEY, GOOGLE_GEOCODING_API_KEY               (maps/geocode)
#   RECAPTCHA_SECRET_KEY                        (signup captcha)
#   VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT          (web push)
#   ECOCASH_*/ONEMONEY_*/MUKURU_*/WISE_*/WORLDREMIT_* (regional payout rails)
# (Non-secret values like AI_MODEL/LOG_LEVEL can instead go in
#  PROD_APP_ENVIRONMENT_JSON below — same effect, just not stored as a secret.)
#
# Minimal launch value (boots green + email works):
gh secret set PROD_APP_SECRETS_JSON -R Eqaya/eqaya_infra -b '{
  "AWS_SES_ENABLED": "true",
  "AWS_SES_FROM_EMAIL": "info@eqaya.com"
}'
```

> SAFETY: never set `MOCK_PAYMENTS=true` in prod — validateEnv.js throws and
> refuses to start (intentional guard against mocked withdrawals going live).

## 4. GitHub variables (optional but recommended)

```bash
# Ops + budget alert recipients (feeds BOTH the cost budget AND the new
# operational CloudWatch alarms via budget_alert_emails).
gh variable set PROD_BUDGET_ALERT_EMAILS_JSON -R Eqaya/eqaya_infra \
  -b '["ops@eqaya.com"]'

# Non-secret extra env for the container (optional).
gh variable set PROD_APP_ENVIRONMENT_JSON -R Eqaya/eqaya_infra -b '{}'

# Which app repo/ref to build. Defaults: <owner>/eqaya-platform @ main.
# Set EQAYA_APP_REF if you deploy from a branch other than main.
gh variable set EQAYA_APP_REF -R Eqaya/eqaya_infra -b "main"
```

## 5. SES (so email works at runtime — not a Terraform blocker)

- Confirm the `eqaya.com` domain identity is verified in SES **us-east-1**
  (same account/region as dev, so it should already be verified and reused).
- Confirm the account is **out of the SES sandbox** (it is if dev already
  emails real users). Otherwise request production access.

```bash
aws ses get-identity-verification-attributes --identities eqaya.com --region us-east-1
aws sesv2 get-account --region us-east-1 --query 'ProductionAccessEnabled'
```

## 6. Trigger the deploy

Push to `release` (or run the workflow manually). The pipeline will:
validate → assume the OIDC role → bootstrap ECR → build & push the app image →
`terraform plan` → **pause for your approval** (step 2) → apply → wait for ECS
to stabilize.

---

### Notes
- The deploy role gets `AdministratorAccess` for simplicity. Tighten to a
  scoped policy once the resource set is stable.
- First apply is slow (ACM DNS validation + RDS Multi-AZ create can take
  10-20 min). The `ecs wait services-stable` step will hold until tasks are
  healthy or it times out.
