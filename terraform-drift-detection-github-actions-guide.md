# Terraform Drift Detection with GitHub Actions
### An Alternative to the Jenkins Setup — No Separate CI Server Needed

---

## Why This Is Simpler Than the Jenkins Version

With GitHub Actions, you don't need a separate server, webhook setup, or job creation UI — the workflow lives as a file inside your repo, and GitHub itself handles the scheduling and execution. If you've already gone through the Jenkins drift detection guide, most of the concepts here will feel familiar — this is the same idea, implemented natively in GitHub.

---

## Step 1: Store Your AWS Credentials as GitHub Secrets

Instead of Jenkins Credentials, GitHub Actions uses **repository secrets**.

1. Go to your repo → **Settings**
2. Left sidebar → **Secrets and variables → Actions**
3. Click **New repository secret**
4. Add these two, one at a time:
   - Name: `AWS_ACCESS_KEY_ID` → Value: your access key
   - Name: `AWS_SECRET_ACCESS_KEY` → Value: your secret key
5. Click **Add secret** for each

## Step 2: Add Your Slack Webhook as a Secret Too (if you want notifications)

Using the same Slack Incoming Webhook URL from the Jenkins setup (see `terraform-drift-detection-guide.md`, Part 3, if you haven't created one yet):

1. **Settings → Secrets and variables → Actions → New repository secret**
2. Name: `SLACK_WEBHOOK_URL` → Value: `https://hooks.slack.com/services/...`

## Step 3: Create the Workflow File

GitHub Actions workflows live in a specific folder: `.github/workflows/`. Create this file:

```
.github/workflows/drift-detection.yml
```

## Step 4: Write the Workflow

```yaml
name: Terraform Drift Detection

on:
  schedule:
    - cron: '0 6 * * *'    # runs daily at 6 AM UTC
  workflow_dispatch:        # also allows manual trigger from GitHub UI

jobs:
  drift-check:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: tf-resources-ec2

    env:
      AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
      AWS_REGION: us-east-1

    steps:
      - name: Checkout repo
        uses: actions/checkout@v4

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.10.0"

      - name: Terraform Init
        run: terraform init -input=false

      - name: Select Workspace
        run: terraform workspace select dev || terraform workspace new dev

      - name: Terraform Plan (Drift Check)
        id: plan
        run: |
          terraform plan -detailed-exitcode -out=driftplan -input=false
        continue-on-error: true

      - name: Report drift status
        run: |
          if [ "${{ steps.plan.outcome }}" == "success" ]; then
            echo "No drift detected."
          elif [ "${{ steps.plan.outputs.exitcode }}" == "2" ]; then
            echo "Drift detected!"
          else
            echo "Plan failed with an error."
            exit 1
          fi

      - name: Notify Slack on drift
        if: steps.plan.outcome == 'failure'
        run: |
          curl -X POST -H 'Content-type: application/json' \
          --data "{\"text\":\"⚠️ Terraform drift detected in *dev* environment. Check the workflow run: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}\"}" \
          ${{ secrets.SLACK_WEBHOOK_URL }}
```

---

## Breaking Down What's Different from Jenkins (and Why)

### Scheduling — `on: schedule`

```yaml
on:
  schedule:
    - cron: '0 6 * * *'
  workflow_dispatch:
```

This is GitHub Actions' equivalent of Jenkins' "Build periodically." Same cron syntax you already know from Jenkins. `workflow_dispatch` additionally adds a **"Run workflow"** button in the GitHub UI — the equivalent of Jenkins' "Build Now," so you can test it manually anytime without waiting for the schedule.

> **Note:** GitHub Actions cron schedules run in **UTC**, not your local timezone. Adjust the hour in the cron expression to account for the difference if timing matters to you.

### Detecting Exit Code 2 — Slightly Different Mechanism Than Jenkins

GitHub Actions doesn't have Jenkins' `returnStatus: true` pattern exactly — instead, we use `continue-on-error: true` on the plan step, which lets the workflow continue even if `terraform plan` exits with a non-zero code (remember: exit code `2` means "drift found," and would normally be treated as a failure).

`steps.plan.outcome` then tells us whether that step technically "failed" (`failure`) or "succeeded" (`success`) — which maps directly to whether drift was found, since exit code `0` = success, and exit code `2` = failure (in Actions' eyes), even though for our purposes exit code `2` isn't really an "error," just "changes found."

### The Slack Notification Step

```yaml
- name: Notify Slack on drift
  if: steps.plan.outcome == 'failure'
  run: |
    curl -X POST -H 'Content-type: application/json' \
    --data "{\"text\":\"⚠️ Terraform drift detected...\"}" \
    ${{ secrets.SLACK_WEBHOOK_URL }}
```

Unlike Jenkins (which has a dedicated `slackSend()` step from the Slack Notification Plugin), GitHub Actions doesn't need a plugin at all — it just uses `curl` to POST directly to your Slack webhook URL. Same webhook you set up earlier for Jenkins, just called a slightly different way.

---

## Step 5: Commit and Push

```bash
git add .github/workflows/drift-detection.yml
git commit -m "add drift detection GitHub Action"
git push
```

## Step 6: Test It Manually

1. Go to your repo on GitHub → **Actions** tab
2. In the left sidebar, click **Terraform Drift Detection**
3. Click **Run workflow** (top right) → **Run workflow** button
4. Watch it run — click into the run to see live logs, same as Jenkins console output

## Step 7: Verify Scheduling Is Active

Once pushed, GitHub automatically picks up the `schedule` trigger — no separate configuration step needed (unlike Jenkins where you had to check a box or add a `triggers` block separately). Just confirm it by checking **Actions → Terraform Drift Detection** — you'll see past/scheduled runs listed there once it starts firing.

---

## Quick Comparison: Jenkins vs GitHub Actions for This Task

| | Jenkins | GitHub Actions |
|---|---|---|
| Where the pipeline lives | Separate `Jenkinsfile.drift`, configured via Jenkins job UI | `.github/workflows/drift-detection.yml`, entirely in-repo |
| Needs a separate server | Yes — your own Jenkins instance | No — GitHub runs it on their infrastructure |
| Credentials storage | Jenkins Credentials | GitHub Secrets |
| Manual trigger | "Build Now" button | `workflow_dispatch` + "Run workflow" button |
| Cron scheduling | Build Triggers UI or `triggers { cron(...) }` in file | `on: schedule` in the YAML file |
| Slack integration | Slack Notification Plugin + `slackSend()` | Plain `curl` POST to webhook URL |
| Timezone for cron | Server's local timezone (whatever Jenkins host is set to) | Always UTC |

## One Thing to Double Check

Since your `.tf` files live in `tf-resources-ec2/` (not the repo root), the `working-directory: tf-resources-ec2` setting under `defaults: run:` handles that — it's the GitHub Actions equivalent of Jenkins' `dir('tf-resources-ec2') { }` wrapper, applied once for the whole job instead of per-step.

---

## Extending to Multiple Environments (dev + stage)

Just like the Jenkins version, you can loop through both workspaces in a single run using a matrix strategy:

```yaml
jobs:
  drift-check:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        environment: [dev, stage]
    defaults:
      run:
        working-directory: tf-resources-ec2

    env:
      AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
      AWS_REGION: us-east-1

    steps:
      - name: Checkout repo
        uses: actions/checkout@v4

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.10.0"

      - name: Terraform Init
        run: terraform init -input=false

      - name: Select Workspace
        run: terraform workspace select ${{ matrix.environment }} || terraform workspace new ${{ matrix.environment }}

      - name: Terraform Plan (Drift Check)
        id: plan
        run: terraform plan -detailed-exitcode -out=driftplan -input=false
        continue-on-error: true

      - name: Notify Slack on drift
        if: steps.plan.outcome == 'failure'
        run: |
          curl -X POST -H 'Content-type: application/json' \
          --data "{\"text\":\"⚠️ Terraform drift detected in *${{ matrix.environment }}* environment. Check the workflow run: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}\"}" \
          ${{ secrets.SLACK_WEBHOOK_URL }}
```

`strategy: matrix: environment: [dev, stage]` tells GitHub Actions to run this entire job **twice in parallel** — once with `dev`, once with `stage` — substituting `${{ matrix.environment }}` wherever it appears. This is the GitHub Actions equivalent of the `['dev', 'stage'].each { env -> ... }` loop shown in the Jenkins multi-environment guide, but runs both checks simultaneously instead of one after another.
