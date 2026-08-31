# Automating Infrastructure Provisioning with Jenkins + Terraform

A beginner-friendly, step-by-step guide to setting up automatic infra provisioning using **Terraform + AWS + GitHub + Jenkins**.

---

## Overview

The core idea: treat infrastructure as code, store it in version control, and let Jenkins detect changes and apply them automatically — with guardrails so "automatic" doesn't mean "reckless."

**Flow:** `git push` → GitHub webhook → Jenkins triggers → `terraform plan` → `terraform apply` → Infra updated

---

## Step 1: Install Prerequisites on Your Jenkins Server

```bash
# Update system
sudo apt update

# Install Java (Jenkins needs it)
sudo apt install openjdk-17-jdk -y

# Install Jenkins
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key | sudo tee \
  /usr/share/keyrings/jenkins-keyring.asc > /dev/null
echo deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] \
  https://pkg.jenkins.io/debian-stable binary/ | sudo tee \
  /etc/apt/sources.list.d/jenkins.list > /dev/null
sudo apt update
sudo apt install jenkins -y

# Start Jenkins
sudo systemctl enable jenkins
sudo systemctl start jenkins
```

Check it's running: open `http://<your-server-ip>:8080` in a browser.

```bash
# Get the initial admin password to unlock Jenkins
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

---

## Step 2: Install Terraform on the Jenkins Server

```bash
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update
sudo apt install terraform -y

# Verify
terraform -version
```

---

## Step 3: Install Required Jenkins Plugins

In Jenkins UI: **Manage Jenkins → Plugins → Available plugins**, search and install:

- `Git` (usually pre-installed)
- `Pipeline`
- `GitHub Integration`
- `Credentials Binding`

---

## Step 4: Add AWS Credentials to Jenkins

**Manage Jenkins → Credentials → System → Global credentials → Add Credentials**

- Kind: `Secret text` (or "AWS Credentials" if that plugin is installed)
- Add your `AWS_ACCESS_KEY_ID` as one credential (ID: `aws-access-key`)
- Add your `AWS_SECRET_ACCESS_KEY` as another (ID: `aws-secret-key`)

---

## Step 5: Create Your Terraform Repo

On your local machine:

```bash
mkdir terraform-infra && cd terraform-infra
git init
```

Create `main.tf`:

```hcl
provider "aws" {
  region = "us-east-1"
}

resource "aws_s3_bucket" "test_bucket" {
  bucket = "my-jenkins-auto-infra-test-bucket-12345"
}
```

Push it to GitHub:

```bash
git add .
git commit -m "initial infra"
 git remote add origin https://github.com/Yaathvik2020/practice-branch.git
 git pull origin main --rebase
git branch -M main
git push -u origin main
```

---

## Step 6: Add a Jenkinsfile to the Same Repo

Create `Jenkinsfile` in the repo root:

```groovy
pipeline{
    agent any
    environment{
        AWS_ACCESS_KEY_ID =credentials('aws-access-key')
        AWS_SECRET_ACCESS_KEY = credentials('aws-secret-key')
    }
    stages{
        stage('checkout'){
            steps{
                   echo 'scm passed'
                   git branch:'main' , url: 'https://github.com/Yaathvik2020/devops-avenue.git'
            }
        }
         stage('terraform init') {
            steps {
                dir('yt-videos/k8s-aws-load-balancer/tf-resources') {
                sh 'terraform init -input=false'
                }
            }
        }

        stage('terraform plan') {
            steps {
                dir('yt-videos/k8s-aws-load-balancer/tf-resources') {
                sh 'terraform plan -out=tfplan -input=false'
                }
            }
        }

        stage('terraform apply') {
            steps {
                dir('yt-videos/k8s-aws-load-balancer/tf-resources') {
                sh 'terraform apply -input=false -auto-approve tfplan'
                }
            }
        
    }
  }
}
*********************AWS Credential plugin as credential store********************
pipeline{
    agent any 
    stages{
        stage('check out scm'){
            steps{
                cleanWs()
                git branch: 'main' ,url: 'https://github.com/Yaathvik2020/practice-branch.git'
            }
        }
        stage('terraform run'){
            steps{
                withCredentials([[
                    $class: 'AmazonWebServicesCredentialsBinding',
                    credentialsId: 'aws-creds'
                ]]) {
            dir('tf-resources-ec2'){
                sh 'terraform init -input=false'
                sh 'terraform plan -out=tfplan -input=false'
                sh 'terraform apply -input=false -auto-approve tfplan'
            }
            }
        }
        }
        stage('destroy'){
            steps{
            withCredentials([[
                    $class: 'AmazonWebServicesCredentialsBinding',
                    credentialsId: 'aws-creds'
                ]]) {
            dir('tf-resources-ec2'){
                sh 'terraform destroy -input=false -auto-approve'
            }
            }
        }
    }
}
post {
        success {
            echo 'Infra applied successfully.'
        }
        failure {
            echo 'Something went wrong.'
        }
    }
}       

```

Push this too:

```bash
git add Jenkinsfile
git commit -m "add jenkinsfile"
git push
```

---

## Step 7: Create the Jenkins Job

1. Jenkins dashboard → **New Item**
2. Name it `infra-pipeline`, choose **Pipeline**, click OK
3. Under **Pipeline** section: choose **Pipeline script from SCM**
4. SCM: `Git`
5. Repository URL: your GitHub repo URL
6. Branch: `*/main`
7. Script Path: `Jenkinsfile`
8. Save

---

## Step 8: Set Up Auto-Trigger on Every Push( pipeline should  be running fro pipeline scri] from SCM  in the defination)

This is the part that makes it "automatic."

1. In your Jenkins job → **Configure → Build Triggers** → check **GitHub hook trigger for GITScm polling**
2. On GitHub: go to your repo → **Settings → Webhooks → Add webhook**
   - Payload URL: `http://<your-jenkins-server-ip>:8080/github-webhook/`
   - Content type: `application/json`
   - Trigger: "Just the push event"
3. Save

Now, every time you `git push` a change to `main.tf`, GitHub notifies Jenkins → Jenkins pulls the code → runs `terraform plan` → runs `terraform apply` automatically.

---

## Step 9: Test It

Make a small change locally, e.g. add a tag to your bucket:

```hcl
resource "aws_s3_bucket" "test_bucket" {
  bucket = "my-jenkins-auto-infra-test-bucket-12345"
  tags = {
    Environment = "dev"
  }
}
```

```bash
git add main.tf
git commit -m "add tag to bucket"
git push
```

Watch Jenkins — a build should trigger within seconds and apply the change automatically.

---

## Safety Note for Beginners

The pipeline above uses `-auto-approve`, meaning **every change applies with no human check** — fine for learning/sandbox AWS accounts, 
risky for anything real.

Once comfortable, the next step is adding a **manual approval gate** (`input` in Jenkinsfile) before `apply` 
runs on production infra, so you don't accidentally delete something important.

### Example: Adding a Manual Approval Stage

```groovy
pipeline {
    agent any

    environment {
        AWS_ACCESS_KEY_ID     = credentials('aws-access-key')
        AWS_SECRET_ACCESS_KEY = credentials('aws-secret-key')
    }

    stages {
        stage('Cleanup') {
            steps {
                cleanWs()
            }
        }

        stage('Checkout') {
            steps {
                git branch: 'main', url: 'https://github.com/Yaathvik2020/practice-branch.git'
            }
        }

        stage('Terraform Init') {
            steps {
                sh 'terraform init -input=false'
            }
        }

        stage('Terraform Plan') {
            steps {
                sh 'terraform plan -out=tfplan -input=false'
            }
        }

        stage('Approval') {
            steps {
                script {
                    input message: "Review the plan above. Apply this Terraform plan?", ok: "Apply"
                }
            }
        }

        stage('Terraform Apply') {
            steps {
                sh 'terraform apply -input=false tfplan'
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

Place this stage between `Terraform Plan` and `Terraform Apply` to require a human click before applying changes.

---

## Guardrails Worth Adding Later

| Guardrail | Purpose |
|---|---|
| Remote state with locking (S3 + DynamoDB) | Prevents concurrent runs from corrupting state |
| Policy-as-code (OPA/Conftest, Sentinel) | Blocks risky changes automatically |
| Slack/Teams notifications | Alerts team on every apply (success/failure) |
| Branch-based rules | Auto-apply on `dev`, require approval on `main`/`prod` |
| Drift detection job (scheduled) | Catches manual changes made outside the pipeline |

---

## Decision Guide: When to Auto-Apply vs. Require Approval

| Scope of Change | Recommended Flow |
|---|---|
| Tag/metadata updates, non-prod scaling | Auto-plan → auto-apply, notify only |
| New resources, config changes in staging | Auto-plan → auto-apply, notify only |
| Anything touching prod, IAM, networking, or deletions | Auto-plan → require manual approval |
| Drift detected outside pipeline | Alert first; auto-correct only if confident in drift-detection logic |
