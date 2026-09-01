# Terraform Drift Detection with Jenkins
### A Beginner's Guide — Automatically Catching Manual/Out-of-Band Changes

---

## Part 1: What Problem Are We Solving?

Imagine this scenario:

1. You use Jenkins + Terraform to create an EC2 instance
2. A week later, someone (maybe even you) logs into **AWS Console directly** and manually changes something — say, opens up an extra port on the security group
3. Terraform has **no idea** this happened, because the change didn't go through Terraform at all

This mismatch — "what Terraform *thinks* exists" vs. "what *actually* exists in AWS" — is called **drift**.

**Drift detection** = a job that periodically checks for this mismatch and tells you about it, **without changing anything**. It's purely a "heads up, something doesn't match" alert system — it never auto-applies fixes, since a manual change might have been an intentional emergency fix someone needed to make.

## The Tool That Makes This Possible: `terraform plan`

You likely already know `terraform plan` — it shows you what *would* change if you ran `apply`, by comparing your `.tf` code against the real current state of AWS. We're going to reuse this exact same command, just run it **on a schedule automatically**, and have Jenkins read its result to decide whether to alert you.

---

## Part 2: Step-by-Step Setup

### Step 1: Create a new, separate Jenkins job

This should be a **new job**, separate from your existing `infra-pipeline` and `infra-destroy` jobs — its only purpose is checking for drift, never creating or destroying anything.

1. Jenkins dashboard → **New Item**
2. Name it: `infra-drift-check`
3. Select **Pipeline**
4. Click **OK**

### Step 2: Point it at your same GitHub repo

On the job's **Configure** page, scroll to **Pipeline** and set:

```
Definition:        Pipeline script from SCM
SCM:                Git
Repository URL:     https://github.com/Yaathvik2020/practice-branch.git
Credentials:        (your existing GitHub credential)
Branches to build:  */main
Script Path:        Jenkinsfile.drift
```

We're using a **new filename** (`Jenkinsfile.drift`) so it doesn't interfere with your existing `Jenkinsfile` (apply) or `Jenkinsfile.destroy`.

### Step 3: Set up the schedule (optional if you add it in code — see Step 5)

1. Still on the **Configure** page, scroll to **Build Triggers**
2. Check the box: **"Build periodically"**
3. In the text box that appears, type:
   ```
   H 6 * * *
   ```
4. Save

#### What does `H 6 * * *` mean?

This is called a **cron expression** — a standard way of scheduling "run this at X time." It has 5 parts:

```
H 6 * * *
│ │ │ │ │
│ │ │ │ └── day of week (* = every day)
│ │ │ └──── month (* = every month)
│ │ └────── day of month (* = every day)
│ └──────── hour (6 = 6 AM)
└────────── minute (H = Jenkins picks a random minute, spreads out load)
```

So this means: **"run this job once a day, sometime around 6 AM."** That's it — no code needed for scheduling if you set it here.

**Other common schedules:**

| Frequency | Cron expression |
|---|---|
| Every day at 6 AM | `H 6 * * *` |
| Every 6 hours | `H */6 * * *` |
| Every Monday at 9 AM | `H 9 * * 1` |
| Every hour | `H * * * *` |

### Step 4: Write the `Jenkinsfile.drift` file — built piece by piece

Let's build this in parts so each concept is clear before seeing the whole file.

#### Part A: Basic structure (same pattern as your other Jenkinsfiles)

```groovy
pipeline {
    agent any

    environment {
        AWS_ACCESS_KEY_ID     = credentials('aws-access-key')
        AWS_SECRET_ACCESS_KEY = credentials('aws-secret-key')
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Terraform Init') {
            steps {
                dir('tf-resources-ec2') {
                    sh 'terraform init -input=false'
                }
            }
        }
    }
}
```

Nothing new here — this is identical to your existing pipeline's setup stages.

#### Part B: The actual drift check — the new concept

```groovy
stage('Check for Drift') {
    steps {
        dir('tf-resources-ec2') {
            sh "terraform workspace select dev || terraform workspace new dev"

            script {
                def result = sh(
                    script: 'terraform plan -detailed-exitcode -out=driftplan -input=false',
                    returnStatus: true
                )

                if (result == 0) {
                    echo "No drift found. Everything matches."
                }
                else if (result == 2) {
                    echo "DRIFT DETECTED! Infrastructure has changed outside of Terraform."
                }
                else {
                    error "Something went wrong running terraform plan"
                }
            }
        }
    }
}
```

#### Breaking down exactly what's happening, line by line

**`returnStatus: true`**
Normally when Jenkins runs a `sh` command, if that command fails, the whole pipeline stops with an error. Adding `returnStatus: true` changes this — instead of stopping, Jenkins just captures the command's **exit code** (a number) into the `result` variable, and continues running.

**`-detailed-exitcode`**
This is a special flag for `terraform plan` that changes what "exit code" it returns:

| Exit code | What it means |
|---|---|
| `0` | No differences — real AWS matches your `.tf` code exactly |
| `2` | Differences found — something doesn't match (this is "drift") |
| `1` | An actual error happened (like a typo in your code) |

Without `-detailed-exitcode`, `terraform plan` always returns `0` no matter what — which would make it impossible for Jenkins to programmatically tell "did it find changes or not?" This flag is the key that unlocks that ability.

**The `if/else` block**
This is just: *"check what number came back, and print a different message depending on the result."* Basic decision-making, same as in any programming language.

### Step 5: Put it all together — full working file

```groovy
pipeline {
    agent any

    environment {
        AWS_ACCESS_KEY_ID     = credentials('aws-access-key')
        AWS_SECRET_ACCESS_KEY = credentials('aws-secret-key')
    }

    triggers {
        cron('H 6 * * *')
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Terraform Init') {
            steps {
                dir('tf-resources-ec2') {
                    sh 'terraform init -input=false'
                }
            }
        }

        stage('Check for Drift') {
            steps {
                dir('tf-resources-ec2') {
                    sh "terraform workspace select dev || terraform workspace new dev"

                    script {
                        def result = sh(
                            script: 'terraform plan -detailed-exitcode -out=driftplan -input=false',
                            returnStatus: true
                        )

                        if (result == 0) {
                            echo "✅ No drift found. Everything matches."
                        }
                        else if (result == 2) {
                            echo "⚠️ DRIFT DETECTED! Infrastructure has changed outside of Terraform."
                            currentBuild.result = 'UNSTABLE'   // marks the build yellow, not green
                        }
                        else {
                            error "Something went wrong running terraform plan"
                        }
                    }
                }
            }
        }
    }

    post {
        always {
            cleanWs()
        }
    }
}
```

**What's new in this full version:**

- `triggers { cron('H 6 * * *') }` — this is an **alternative** to Step 3's UI checkbox. You can set the schedule either in the Jenkins UI (Build Triggers checkbox) **or** directly in code like this — both work identically. Having it in code means it's version-controlled and travels with your repo, which is generally the better practice. If you add this in the file, you can skip Step 3's manual checkbox setup entirely (Jenkins reads the schedule from the Jenkinsfile itself).
- `currentBuild.result = 'UNSTABLE'` — this makes the Jenkins job show up as **yellow** (instead of green) whenever drift is found, so you get a visual signal on the Jenkins dashboard, not just a line buried in the console log.

### Step 6: Push this file to your repo

```bash
git add Jenkinsfile.drift
git commit -m "add scheduled drift detection job"
git push
```

### Step 7: Test it manually first (don't wait for 6 AM)

1. Go to your `infra-drift-check` job in Jenkins
2. Click **Build Now**
3. Watch the console output — you should see either:
   ```
   ✅ No drift found. Everything matches.
   ```
   or
   ```
   ⚠️ DRIFT DETECTED! Infrastructure has changed outside of Terraform.
   ```

### Step 8: Try it out for real — manually create drift to test

To actually see this working, deliberately create some drift:

1. Go to **AWS Console → EC2 → Security Groups**
2. Find your `demo-instance-sg-dev` security group
3. Manually add a new inbound rule (e.g., allow port 443)
4. This change was made **outside Terraform** — exactly what drift detection is meant to catch
5. Go back to Jenkins → run `infra-drift-check` → **Build Now**
6. It should now report "DRIFT DETECTED" and the build turns yellow

Once confirmed working, you can **remove that test rule manually** in AWS Console — or, better, use this as your chance to see the drift-fixing workflow: run your normal `infra-pipeline` apply job, and Terraform will silently remove the manually-added rule to bring things back in line with your code, since it's not in your `.tf` files.

---

## Part 3: Adding Slack Notifications

Right now, drift detection only shows up as a yellow build in Jenkins — you'd have to remember to check the dashboard. Let's make it message you directly in Slack whenever drift is found, so you don't have to go looking for it.

### Step 1: Create a Slack Incoming Webhook (this is how Jenkins "talks" to Slack)

A **webhook** is just a special URL — when Jenkins sends a message to that URL, Slack automatically posts it into a channel you chose. No Slack account credentials are ever shared with Jenkins, just this one URL.

1. Go to [https://api.slack.com/apps](https://api.slack.com/apps)
2. Click **Create New App** → **From scratch**
3. Give it a name (e.g., `Jenkins Drift Alerts`) and select your workspace
4. In the left sidebar, click **Incoming Webhooks**
5. Toggle **Activate Incoming Webhooks** to **On**
6. Click **Add New Webhook to Workspace** (near the bottom)
7. Choose the channel you want alerts posted to (e.g., `#infra-alerts` — create this channel first in Slack if it doesn't exist yet)
8. Click **Allow**
9. You'll now see a **Webhook URL** — it looks like:
   ```
   https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXXXXXX
   ```
   **Copy this URL** — you'll need it in Step 3.

### Step 2: Install the Slack Notification Plugin in Jenkins

1. **Manage Jenkins → Plugins → Available plugins**
2. Search: `Slack Notification`
3. Check the box → **Install**
4. Restart Jenkins if prompted

### Step 3: Configure Slack globally in Jenkins (one-time setup)

1. Go to **Manage Jenkins → System**
2. Scroll down to find the **Slack** section
3. Fill in:
   - **Workspace**: your Slack workspace name (e.g., if your Slack URL is `myteam.slack.com`, enter `myteam`)
   - **Credential**: click **Add** → **Jenkins**
     - Kind: `Secret text`
     - Secret: paste the webhook URL you copied in Step 1
     - ID: `slack-webhook`
     - Click **Add**
   - Select the credential you just created from the dropdown
   - **Default channel**: `#infra-alerts` (or whatever channel you chose)
4. Click **Test Connection** — you should see a test message appear in your Slack channel
5. Click **Save**

### Step 4: Add the Slack notification step to your Jenkinsfile

Update the `Check for Drift` stage to send a Slack message when drift is found:

```groovy
stage('Check for Drift') {
    steps {
        dir('tf-resources-ec2') {
            sh "terraform workspace select dev || terraform workspace new dev"

            script {
                def result = sh(
                    script: 'terraform plan -detailed-exitcode -out=driftplan -input=false',
                    returnStatus: true
                )

                if (result == 0) {
                    echo "✅ No drift found. Everything matches."
                }
                else if (result == 2) {
                    echo "⚠️ DRIFT DETECTED! Infrastructure has changed outside of Terraform."
                    currentBuild.result = 'UNSTABLE'

                    slackSend(
                        channel: '#infra-alerts',
                        color: 'warning',
                        message: "⚠️ *Terraform drift detected* in `dev` environment.\nCheck the build for details: ${env.BUILD_URL}"
                    )
                }
                else {
                    error "Something went wrong running terraform plan"
                }
            }
        }
    }
}
```

### What's new here, explained simply

**`slackSend(...)`** — this is a step added by the Slack Notification Plugin you just installed. It sends a message to Slack. You give it three things:
- `channel` — which Slack channel to post in
- `color` — a colored bar next to the message in Slack (`good` = green, `warning` = yellow, `danger` = red) — purely visual, makes it easy to spot severity at a glance
- `message` — the actual text of the message

**`${env.BUILD_URL}`** — this is a built-in Jenkins variable that automatically contains a clickable link to the exact build that's running. Including it means when you get the Slack alert, you can click straight through to the full console output without hunting for it in Jenkins.

### Step 5: Push and test

```bash
git add Jenkinsfile.drift
git commit -m "add slack notification for drift detection"
git push
```

Run the job manually (**Build Now**) — if you still have the test drift from Part 2, Step 8 in place (the manually-added security group rule), you should see a message appear in your Slack channel within moments of the build running.

### Step 6: Also notify when there's an error (optional, but useful)

You can also get notified if the drift check itself fails (e.g., AWS credentials expired, network issue) rather than just when drift is found — add this to the `post` block at the bottom of your Jenkinsfile:

```groovy
post {
    always {
        cleanWs()
    }
    failure {
        slackSend(
            channel: '#infra-alerts',
            color: 'danger',
            message: "❌ Drift detection job FAILED to run. Check Jenkins: ${env.BUILD_URL}"
        )
    }
}
```

This way, silence from the job doesn't just mean "no drift" — it specifically means "the check ran successfully and found nothing," which is an important distinction (a broken job that never runs would otherwise look identical to "everything's fine").

### Quick summary of what you added

| Piece | What it does |
|---|---|
| Slack Incoming Webhook | A URL that lets Jenkins post messages into a specific Slack channel |
| Slack Notification Plugin | Adds the `slackSend()` step to Jenkins Pipeline |
| Slack credential in Jenkins | Securely stores the webhook URL, same pattern as your AWS credentials |
| `slackSend()` in your Jenkinsfile | Sends the actual alert message when drift is detected |
| `post { failure { ... } }` | Also alerts you if the check itself breaks, not just when drift is found |

---

## Part 4: Quick Summary — What You Built

| Piece | What it does |
|---|---|
| New Jenkins job (`infra-drift-check`) | A dedicated job, separate from apply/destroy |
| `Jenkinsfile.drift` | The pipeline code — checks out repo, runs `terraform plan` |
| `-detailed-exitcode` flag | Makes `terraform plan` return a specific number telling us if drift exists |
| `returnStatus: true` | Lets Jenkins capture that number instead of stopping on "failure" |
| `cron('H 6 * * *')` | Runs this automatically once a day, no manual trigger needed |
| `currentBuild.result = 'UNSTABLE'` | Makes the job show yellow in Jenkins UI when drift is found |

This gives you a genuinely working, automatic "someone changed something without going through Terraform" alarm — running quietly every day in the background, with zero risk of it accidentally applying any changes on its own.

---

## Part 5: Next Steps (Optional, For Later)

Once you're comfortable with this version, natural next steps include:

- **Checking multiple environments** — loop through both `dev` and `stage` workspaces in a single scheduled run, sending a separate Slack message per environment, rather than hardcoding just `dev` as shown in this beginner version.
- **Saving drift history** — archive the `terraform plan` output as a build artifact each run, so you have a historical record of what drifted and when.
- **Email as a backup channel** — the Email Extension Plugin works the same way as Slack (configure once, add a step in the Jenkinsfile) if you want a second notification channel alongside Slack.

These are worth adding once the basic version above is running reliably and you're comfortable with how it works — no need to tackle them all at once.
