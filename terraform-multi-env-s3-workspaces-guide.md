# Terraform Multi-Environment Setup with S3 Remote State
### Real-World Guide: Dev + Stage EC2 Provisioning via Jenkins

---

## What This Guide Covers

This is a complete, from-scratch setup combining two things you need together in a real-world CI/CD pipeline:

1. **Remote state in S3** — so your Terraform state isn't trapped inside a Jenkins workspace folder that gets wiped or isn't shared between jobs
2. **Multiple environments (dev, stage)** — using the *same* Terraform code to create *separate, independent* infrastructure per environment, each tracked in its own isolated state

By the end, you'll be able to click **Build with Parameters** in Jenkins, choose `dev` or `stage`, and get a completely independent EC2 instance for that environment — without ever risking one environment's infrastructure when working on the other.

---

## Part 1: Concepts (Read First)

### Why remote state?

By default, Terraform stores its "memory" of what it created (`terraform.tfstate`) as a local file in whatever folder you ran it from. In Jenkins, that's the job's workspace folder — which gets deleted on cleanup, and isn't shared between different jobs (like your `infra-pipeline` apply job and a separate `infra-destroy` job).

**Solution:** store the state remotely in **Amazon S3**, with **DynamoDB** for locking (so two runs can't corrupt the file by writing at the same time). Every job, from any machine, reads and writes the same central state.

### Why workspaces?

If you just run your existing `.tf` files again to create a "stage" EC2 instance, Terraform checks the **same state file** and sees "an EC2 instance already exists" (from dev) — so it does nothing, or worse, modifies the dev instance instead of creating a new one.

**Solution:** Terraform **workspaces** let you reuse the exact same `.tf` code, but automatically maintain a **separate state file per environment**. Switching workspaces is like switching which "notebook" Terraform is currently writing into.

```
Same .tf code
      │
      ├── workspace: dev    →  state: env:/dev/terraform.tfstate    →  EC2 #1 (dev)
      └── workspace: stage  →  state: env:/stage/terraform.tfstate  →  EC2 #2 (stage)
```

---

## Part 2: One-Time Infrastructure Setup (S3 + DynamoDB)

### Step 1: Create the S3 bucket

```bash
aws s3api create-bucket \
  --bucket yaathvik-terraform-state-2026 \
  --region us-east-1
  ``` 
 ## other region need to add except us-east-1
 ```bash
 aws s3api create-bucket \
  --bucket yaathvik-terraform-state-2026 \
  --region ap-south-1 \
  --create-bucket-configuration LocationConstraint=ap-south-1
```

> Bucket names must be globally unique across all AWS accounts. Adjust the name to something unique to you.

### Step 2: Enable versioning (recovery safety net)

```bash
aws s3api put-bucket-versioning \
  --bucket yaathvik-terraform-state-2026 \
  --versioning-configuration Status=Enabled
```

### Step 3: Create the DynamoDB lock table
aws dynamodb delete-table --table-name YourTableName
```bash
aws dynamodb create-table \
  --table-name terraform-state-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ap-south-1
```

> ## ⚠️ Update: `dynamodb_table` is deprecated — use `use_lockfile` instead
>
> Newer versions of Terraform (1.10+) support native S3 locking through conditional writes, removing the need for a separate DynamoDB table entirely. If you see this warning:
> ```
> Warning: Deprecated Parameter
> The parameter "dynamodb_table" is deprecated. Use parameter "use_lockfile" instead.
> ```
> ...it means your Terraform version supports the simpler approach. **The rest of this guide (Parts 1–13) was written using the DynamoDB approach and still works fine** — DynamoDB locking is not broken, just older. If you'd rather use the current recommended method, see **Part 14: Simplified Locking with `use_lockfile`** at the end of this document, which replaces the DynamoDB steps with a simpler S3-only setup.
>
> | | DynamoDB locking (Parts 1–13) | `use_lockfile` (Part 14) |
> |---|---|---|
> | Extra AWS resource needed | Yes — a DynamoDB table | No — S3 bucket alone is enough |
> | IAM permissions needed | S3 + DynamoDB actions | S3 actions only |
> | Requires Terraform 1.10+ | No | Yes |
>
> If you already created the DynamoDB table and it's working, there's no urgency to switch — both approaches are safe to use.

### Step 4: Grant your Jenkins IAM user access to both

```bash
cat > state-backend-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::yaathvik-terraform-state-2026",
        "arn:aws:s3:::yaathvik-terraform-state-2026/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"],
      "Resource": "arn:aws:dynamodb:us-east-1:*:table/terraform-state-lock"
    }
  ]
}
EOF

aws iam put-user-policy \
  --user-name <your-iam-username> \
  --policy-name terraform-state-access \
  --policy-document file://state-backend-policy.json
```

Replace `<your-iam-username>` with the IAM user behind your Jenkins `aws-creds` credential. Not sure which user that is?

```bash
aws sts get-caller-identity
```

---

## Part 3: Project File Structure

```
tf-resources/
├── 0-provider.tf
├── 1-variable.tf
├── 2-data.tf
├── 3-ec2.tf
├── backend.tf          ← NEW: remote state config
├── dev.tfvars           (optional, if you go the tfvars route instead of workspace tags)
└── stage.tfvars          (optional)
```

---

## Part 4: Configure the Remote Backend

### `backend.tf` (new file)

```hcl
# backend.tf
#
# Tells Terraform to store its state file remotely in S3 instead of
# locally on disk. This makes state visible/shared across every
# Jenkins job and every machine, and prevents it from being lost
# when a Jenkins workspace is cleaned up.

terraform {
  backend "s3" {
    bucket         = "yaathvik-terraform-state-2026"
    key            = "practice-branch/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-state-lock" //deprecated 
    encrypt        = true
  }
}
```
### new version with dynamodb 
``` hcl
terraform {
  backend "s3" {
    bucket       = "yaathvik-terraform-state-2026"
    key          = "practice-branch/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
```

**Note:** when combined with workspaces (next section), Terraform automatically inserts the workspace name into the state path behind the scenes — you don't need to manually change `key` per environment. The actual S3 paths end up looking like:

```
s3://yaathvik-terraform-state-2026/env:/dev/practice-branch/terraform.tfstate
s3://yaathvik-terraform-state-2026/env:/stage/practice-branch/terraform.tfstate
```

---

## Part 5: Update Your Terraform Code to Support Multiple Environments

### `1-variable.tf`

```hcl
variable "aws_region" {
  description = "AWS region to deploy in"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t2.micro"
}

variable "ami_id" {
  description = "AMI ID for the EC2 instance"
  type        = string
  default     = "ami-0c02fb55956c7d316"
}

variable "key_name" {
  description = "Name of the existing EC2 key pair for SSH access"
  type        = string
  default     = ""
}

variable "instance_name" {
  description = "Base name tag for the EC2 instance (environment name gets appended automatically)"
  type        = string
  default     = "demo-ec2"
}
```

### `3-ec2.tf` — use `terraform.workspace` to keep environments distinct

```hcl
resource "aws_security_group" "demo_sg" {
  name        = "demo-instance-sg-${terraform.workspace}"   # e.g. demo-instance-sg-dev
  description = "Allow SSH and HTTP"
  vpc_id      = data.aws_vpc.selected.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "demo-instance-sg-${terraform.workspace}"
  }
}

resource "aws_instance" "demo_ec2" {
  ami                          = var.ami_id
  instance_type                = var.instance_type
  key_name                     = var.key_name != "" ? var.key_name : null
  subnet_id                    = tolist(data.aws_subnets.public.ids)[0]
  vpc_security_group_ids       = [aws_security_group.demo_sg.id]
  associate_public_ip_address  = true

  tags = {
    Name        = "${var.instance_name}-${terraform.workspace}"   # e.g. demo-ec2-dev
    Environment = terraform.workspace
  }
}

output "instance_public_ip" {
  value = aws_instance.demo_ec2.public_ip
}

output "environment" {
  value = terraform.workspace
}
```

**What `terraform.workspace` does:** it's a built-in reference that automatically returns the name of whichever workspace is currently active (`dev`, `stage`, etc.) — no extra variable needed, Terraform tracks this itself.

### Commit and push

```bash
git add backend.tf 1-variable.tf 3-ec2.tf
git commit -m "add S3 remote backend and workspace-based multi-env support"
git push
```

---

## Part 6: Initialize Backend and Create Workspaces

Run these once (locally, or as a one-time manual Jenkins build):

```bash
cd tf-resources
terraform init
```

If you have existing local state (from your original dev instance before this setup), Terraform will ask to migrate it:
```
Do you want to copy existing state to the new backend?
  Enter a value: yes
```

### Create the workspaces

```bash
terraform workspace new dev
terraform workspace new stage

terraform workspace list
```

Expected output:
```
  default
* dev
  stage
```

### If you had an existing dev EC2 instance under the `default` workspace — migrate it into `dev`

```bash
terraform workspace select default
terraform state pull > default.tfstate

terraform workspace select dev
terraform state push default.tfstate

terraform state list   # confirm your dev resources now appear here
```

---

## Part 7: Jenkins Job Setup — Parameterized for Environment Choice

### Step 1: Make the job accept a parameter

1. Open your `infra-pipeline` job → **Configure**
2. Check **"This project is parameterized"**
3. **Add Parameter → Choice Parameter**
   - Name: `ENVIRONMENT`
   - Choices:
     ```
     dev
     stage
     ```
4. Save

### Step 2: Full Jenkinsfile with environment + workspace + approval gate

```groovy
pipeline {
    agent any

    parameters {
        choice(name: 'ENVIRONMENT', choices: ['dev', 'stage'], description: 'Target environment')
    }

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

        stage('Select Workspace') {
            steps {
                dir('tf-resources-ec2') {
                    sh "terraform workspace select ${ENVIRONMENT} || terraform workspace new ${ENVIRONMENT}"
                }
            }
        }

        stage('Terraform Plan') {
            steps {
                dir('tf-resources-ec2') {
                    sh 'terraform plan -out=tfplan -input=false'
                }
            }
        }

        stage('Approval') {
            steps {
                script {
                    timeout(time: 15, unit: 'MINUTES') {
                        input message: "Apply this plan for ${ENVIRONMENT}?", ok: "Apply"
                    }
                }
            }
        }

        stage('Terraform Apply') {
            steps {
                dir('tf-resources-ec2') {
                    sh 'terraform apply -input=false tfplan'
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

Commit and push:

```bash
git add Jenkinsfile
git commit -m "parameterize pipeline for multi-environment deploys"
git push
```

### Step 3: Update your destroy job the same way

Your `infra-destroy` job (from earlier) also needs the `ENVIRONMENT` parameter and workspace-select stage — otherwise it might destroy the wrong environment.

**`Jenkinsfile.destroy`:**

```groovy
pipeline {
    agent any

    parameters {
        choice(name: 'ENVIRONMENT', choices: ['dev', 'stage'], description: 'Environment to destroy')
    }

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
                sh 'terraform init -input=false'
            }
        }

        stage('Select Workspace') {
            steps {
                sh """
                    terraform workspace select ${ENVIRONMENT} || terraform workspace new ${ENVIRONMENT}
                """
            }
        }

        stage('Terraform Plan Destroy') {
            steps {
                sh 'terraform plan -destroy -out=tfplan -input=false'
            }
        }

        stage('Approval') {
            steps {
                script {
                    timeout(time: 10, unit: 'MINUTES') {
                        input message: "This will DESTROY all resources in ${ENVIRONMENT}. Proceed?", ok: "Destroy"
                    }
                }
            }
        }

        stage('Terraform Destroy') {
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

Commit and push:

```bash
git add Jenkinsfile.destroy
git commit -m "parameterize destroy pipeline for multi-environment"
git push
```

Make sure the `infra-destroy` job also has the `ENVIRONMENT` choice parameter added (same as Step 1 above), and that **"GitHub hook trigger"** stays **unchecked** on this job — destroy should only ever run manually.

---

## Part 8: Running It

### To create/update the stage environment

1. Go to `infra-pipeline` job in Jenkins
2. Click **Build with Parameters**
3. Select `ENVIRONMENT = stage`
4. Click **Build**

**What happens internally:**
1. `terraform init` connects to the shared S3 backend
2. `terraform workspace select stage` switches to (or creates) the `stage` workspace — this points Terraform at a completely separate state file
3. `terraform plan` compares your `.tf` code against `stage`'s state (which is currently empty) → shows "1 to add" for a brand-new EC2 instance
4. You approve
5. A new EC2 instance is created, tagged `demo-ec2-stage`, tracked independently — your `dev` instance is completely untouched

### To destroy only the stage environment later

1. Go to `infra-destroy` job
2. Click **Build with Parameters**
3. Select `ENVIRONMENT = stage`
4. Review the destroy plan, approve
5. Only the stage EC2 instance is destroyed — dev remains running

---

## Part 9: Verifying Everything Is Actually Separated

### Check state per workspace locally

```bash
terraform workspace select dev
terraform state list
# shows dev's EC2 instance and security group

terraform workspace select stage
terraform state list
# shows stage's EC2 instance and security group — separate from dev
```

### Check the actual S3 paths

```bash
aws s3 ls s3://yaathvik-terraform-state-2026/ --recursive
```

Expected output — two separate, independent state files:
```
env:/dev/practice-branch/terraform.tfstate
env:/stage/practice-branch/terraform.tfstate
```

### Check AWS directly

```bash
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=demo-ec2-*" \
  --query 'Reservations[*].Instances[*].{ID:InstanceId,Name:Tags[?Key==`Name`]|[0].Value,State:State.Name}' \
  --output table
```

You should see two separate instances listed, e.g. `demo-ec2-dev` and `demo-ec2-stage`, each with its own instance ID.

---

## Part 10: Full Picture — How It All Connects

```
                        +----------------------------+
                        |   GitHub Repo              |
                        |   (.tf files, Jenkinsfile) |
                        +--------------+-------------+
                                       |
                     +-----------------+-----------------+
                     |                                     |
           infra-pipeline job                     infra-destroy job
        (parameterized: dev/stage)             (parameterized: dev/stage)
                     |                                     |
        +------------+------------+            +-----------+------------+
        |                          |            |                        |
  workspace: dev            workspace: stage    workspace: dev    workspace: stage
        |                          |                    |                |
        v                          v                    v                v
  +-------------+          +-------------+      (destroys dev)   (destroys stage)
  |  S3 State   |          |  S3 State   |
  |  env:/dev/  |          |  env:/stage/|
  +------+------+          +------+------+
         |                        |
         v                        v
   EC2 Instance              EC2 Instance
   "demo-ec2-dev"             "demo-ec2-stage"
```

---

## Part 11: Quick Reference Summary

| Concept | Purpose |
|---|---|
| S3 bucket | Stores the actual `terraform.tfstate` file, shared across all jobs/machines |
| DynamoDB table | Locks state during a run so concurrent runs can't corrupt it |
| `backend.tf` | Configures where state is stored — committed to Git, applies automatically everywhere |
| Terraform workspace | Namespaces state per environment, using the same `.tf` code |
| `terraform.workspace` | Built-in reference to the current workspace name, used in resource names/tags |
| Jenkins `ENVIRONMENT` parameter | Lets you choose which environment to target at build time |
| `terraform workspace select X \|\| terraform workspace new X` | Switches to environment X's state, creating it fresh if it doesn't exist yet 
|

This setup gives you a genuinely production-style workflow: one codebase, multiple isolated environments, centralized and safe state management, and manual approval gates before anything gets created or destroyed.

---

## Part 12: Full Copy-Paste Appendix (Everything in One Place)

This section collects every command and file from the guide above into a single sequential run-through — useful if you're setting this up fresh and want to copy/paste your way through without jumping between sections.

### A. Region gotcha to check first

Before creating anything, confirm which region your AWS CLI is actually configured for. S3 treats `us-east-1` as a special case (no `LocationConstraint` needed), while every other region requires one — mismatching this causes `IllegalLocationConstraintException`.

```bash
aws configure get region
```

If it's not `us-east-1` and you want to use `us-east-1`, set it explicitly:
```bash
aws configure set region us-east-1
```

If you're intentionally using a different region (e.g. `ap-south-1`), add `--create-bucket-configuration LocationConstraint=<region>` to the bucket creation command in Step B, and use that same region everywhere else in this guide (DynamoDB, `backend.tf`, `1-variable.tf`).

### B. Create S3 bucket + enable versioning

```bash
aws s3api create-bucket \
  --bucket yaathvik-terraform-state-2026 \
  --region us-east-1

aws s3api put-bucket-versioning \
  --bucket yaathvik-terraform-state-2026 \
  --versioning-configuration Status=Enabled
```

### C. Create DynamoDB lock table

```bash
aws dynamodb create-table \
  --table-name terraform-state-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

### D. IAM permissions for the Jenkins user

```bash
cat > state-backend-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::yaathvik-terraform-state-2026",
        "arn:aws:s3:::yaathvik-terraform-state-2026/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"],
      "Resource": "arn:aws:dynamodb:us-east-1:*:table/terraform-state-lock"
    }
  ]
}
EOF

aws iam put-user-policy \
  --user-name <your-iam-username> \
  --policy-name terraform-state-access \
  --policy-document file://state-backend-policy.json
```

### E. `0-provider.tf`

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}
```

### F. `backend.tf`

```hcl
terraform {
  backend "s3" {
    bucket         = "yaathvik-terraform-state-2026"
    key            = "practice-branch/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-state-lock"
    encrypt        = true
  }
}
```

### G. `1-variable.tf`

```hcl
variable "aws_region" {
  default = "us-east-1"
}

variable "instance_type" {
  default = "t2.micro"
}

variable "ami_id" {
  default = "ami-0c02fb55956c7d316"
}

variable "key_name" {
  default = ""
}

variable "instance_name" {
  default = "demo-ec2"
}
```

### H. `2-data.tf`

```hcl
data "aws_vpcs" "available" {}

data "aws_vpc" "selected" {
  id = tolist(data.aws_vpcs.available.ids)[0]
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected.id]
  }

  filter {
    name   = "map-public-ip-on-launch"
    values = ["true"]
  }
}
```

### I. `3-ec2.tf`

```hcl
resource "aws_security_group" "demo_sg" {
  name        = "demo-instance-sg-${terraform.workspace}"
  description = "Allow SSH and HTTP"
  vpc_id      = data.aws_vpc.selected.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "demo-instance-sg-${terraform.workspace}"
  }
}

resource "aws_instance" "demo_ec2" {
  ami                          = var.ami_id
  instance_type                = var.instance_type
  key_name                     = var.key_name != "" ? var.key_name : null
  subnet_id                    = tolist(data.aws_subnets.public.ids)[0]
  vpc_security_group_ids       = [aws_security_group.demo_sg.id]
  associate_public_ip_address  = true

  tags = {
    Name        = "${var.instance_name}-${terraform.workspace}"
    Environment = terraform.workspace
  }
}

output "instance_public_ip" {
  value = aws_instance.demo_ec2.public_ip
}

output "environment" {
  value = terraform.workspace
}
```

### J. Push all `.tf` files to GitHub

```bash
git add .
git commit -m "add multi-env terraform setup with s3 backend"
git push
```

### K. Initialize backend locally (one-time)

```bash
cd tf-resources
terraform init
```

If prompted to migrate existing local state into S3, type `yes`.

### L. Create workspaces

```bash
terraform workspace new dev
terraform workspace new stage
terraform workspace list
```

### M. Verify the automatic per-environment path behavior

```bash
terraform workspace select dev
terraform plan
aws s3 ls s3://yaathvik-terraform-state-2026/env:/dev/ --recursive

terraform workspace select stage
terraform plan
aws s3 ls s3://yaathvik-terraform-state-2026/env:/stage/ --recursive
```

Each command should show a separate, independent state file path — confirming dev and stage are fully isolated even though they share the same `backend.tf` and `key` value (see Part 12 note below, or the earlier explanation of how Terraform auto-prefixes the path with `env:/<workspace>/`).

### N. `Jenkinsfile` (apply pipeline)

```groovy
pipeline {
    agent any

    parameters {
        choice(name: 'ENVIRONMENT', choices: ['dev', 'stage'], description: 'Target environment')
    }

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
                checkout scm
            }
        }

        stage('Terraform Init') {
            steps {
                sh 'terraform init -input=false'
            }
        }

        stage('Select Workspace') {
            steps {
                sh """
                    terraform workspace select ${ENVIRONMENT} || terraform workspace new ${ENVIRONMENT}
                """
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
                    timeout(time: 15, unit: 'MINUTES') {
                        input message: "Apply this plan for ${ENVIRONMENT}?", ok: "Apply"
                    }
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

### O. `Jenkinsfile.destroy` (destroy pipeline)

```groovy
pipeline {
    agent any

    parameters {
        choice(name: 'ENVIRONMENT', choices: ['dev', 'stage'], description: 'Environment to destroy')
    }

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
                sh 'terraform init -input=false'
            }
        }

        stage('Select Workspace') {
            steps {
                sh """
                    terraform workspace select ${ENVIRONMENT} || terraform workspace new ${ENVIRONMENT}
                """
            }
        }

        stage('Terraform Plan Destroy') {
            steps {
                sh 'terraform plan -destroy -out=tfplan -input=false'
            }
        }

        stage('Approval') {
            steps {
                script {
                    timeout(time: 10, unit: 'MINUTES') {
                        input message: "This will DESTROY all resources in ${ENVIRONMENT}. Proceed?", ok: "Destroy"
                    }
                }
            }
        }

        stage('Terraform Destroy') {
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

### P. Push Jenkinsfiles

```bash
git add Jenkinsfile Jenkinsfile.destroy
git commit -m "add apply and destroy pipelines with workspace support"
git push
```

### Q. Jenkins job configuration (both jobs)

For **both** `infra-pipeline` and `infra-destroy`:

1. Job → **Configure**
2. Check **"This project is parameterized"**
3. **Add Parameter → Choice Parameter** → Name: `ENVIRONMENT`, Choices: `dev` / `stage`
4. **Pipeline → Definition**: `Pipeline script from SCM`
5. **SCM**: Git, Repository URL: your repo, Branch: `*/main`
6. **Script Path**: `Jenkinsfile` (for the apply job) or `Jenkinsfile.destroy` (for the destroy job)
7. Save

> Remember: leave **"GitHub hook trigger for GITScm polling"** unchecked on `infra-destroy` — destroy should only ever run manually, never automatically from a push.

### R. Run it

```
Jenkins → infra-pipeline → Build with Parameters → ENVIRONMENT = stage → Build
```

### S. Verify both environments exist independently

```bash
terraform workspace select dev
terraform state list

terraform workspace select stage
terraform state list

aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=demo-ec2-*" \
  --query 'Reservations[*].Instances[*].{ID:InstanceId,Name:Tags[?Key==`Name`]|[0].Value,State:State.Name}' \
  --output table
```

You should see two separate EC2 instances, `demo-ec2-dev` and `demo-ec2-stage`, each with a distinct instance ID and each tracked in its own isolated S3 state file.

---

## Part 13: Optional — Per-Environment Settings with `.tfvars` Files

Everything above (Parts 1–12) gets you **state isolation** between dev and stage using workspaces — but both environments still use the *same* variable values (same instance type, same defaults from `1-variable.tf`). This section is optional and covers how to also give dev and stage **genuinely different configurations** (e.g., a smaller instance type for dev, a bigger one for stage).

### When to use this

| Workspaces only (Parts 1–12) | Workspaces + `.tfvars` (this section) |
|---|---|
| Same settings for dev and stage, just separate state files | Dev and stage can have different instance types, tags, or any other variable value |
| Simpler — no extra files | More explicit — one file per environment shows exactly what differs |

These two approaches aren't mutually exclusive — workspaces handle **state isolation**, `.tfvars` files handle **configuration differences**. Using both together is the most common real-world pattern.

### Step 1: Create the `.tfvars` files

**`dev.tfvars`:**
```hcl
instance_name = "demo-ec2"
instance_type = "t2.micro"
```

**`stage.tfvars`:**
```hcl
instance_name = "demo-ec2"
instance_type = "t2.small"
```

Adjust the values to whatever should actually differ between your environments — instance size, AMI, tags, etc.

### Step 2: No changes needed to `1-variable.tf`

Since `instance_type` and `instance_name` are already declared as variables with defaults, a `.tfvars` file simply **overrides** those defaults whenever it's explicitly loaded — you don't need to modify the variable declarations themselves.

### Step 3: Use `-var-file` when running plan/apply manually

```bash
terraform workspace select dev
terraform plan -var-file="dev.tfvars" -out=tfplan
terraform apply tfplan
```

```bash
terraform workspace select stage
terraform plan -var-file="stage.tfvars" -out=tfplan
terraform apply tfplan
```

The `-var-file` flag tells Terraform to load variable values from that file, overriding whatever defaults exist in `1-variable.tf`.

### Step 4: Wire this into your Jenkinsfile

Update the **Terraform Plan** stage in your `Jenkinsfile` to dynamically pick the matching `.tfvars` file based on the `ENVIRONMENT` parameter:

```groovy
stage('Terraform Plan') {
    steps {
        sh "terraform plan -var-file=${ENVIRONMENT}.tfvars -out=tfplan -input=false"
    }
}
```

Since `${ENVIRONMENT}` resolves to `dev` or `stage` at build time, this automatically loads `dev.tfvars` or `stage.tfvars` — matching whichever file exists with that exact name.

Apply the same change to your `Jenkinsfile.destroy` plan-destroy stage:

```groovy
stage('Terraform Plan Destroy') {
    steps {
        sh "terraform plan -destroy -var-file=${ENVIRONMENT}.tfvars -out=tfplan -input=false"
    }
}
```

### Step 5: Commit and push

```bash
git add dev.tfvars stage.tfvars Jenkinsfile Jenkinsfile.destroy
git commit -m "add per-environment tfvars files"
git push
```

### Step 6: Run it

```
Jenkins → infra-pipeline → Build with Parameters → ENVIRONMENT = stage → Build
```

This now applies `stage.tfvars` values (e.g., `t2.small`) while `dev` keeps using `dev.tfvars` values (e.g., `t2.micro`) — same code, same workspace-based state isolation, but genuinely different configurations per environment.

### Step 7: Verify the override worked

```bash
terraform workspace select stage
terraform plan -var-file="stage.tfvars"
```

Check the plan output and confirm it shows `instance_type = "t2.small"` (or whatever you set) — not the default `t2.micro` from `1-variable.tf`. That confirms the `.tfvars` override is being applied correctly.

### Updated file structure

```
tf-resources/
├── 0-provider.tf
├── 1-variable.tf
├── 2-data.tf
├── 3-ec2.tf
├── backend.tf
├── dev.tfvars
├── stage.tfvars
├── Jenkinsfile
└── Jenkinsfile.destroy
```
