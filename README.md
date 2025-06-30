# Crafty Control EC2 Builder

A simple (and low-cost) auto-ec2 builder to run [Crafty Control](https://craftycontrol.com) (Minecraft server manager) powered by Terraform.

The table below is an _estimate_ of the cost as of the writing of this doc. Per month costs based on 12 Hours of uptime per day.

| Service               | p/hr               | p/mo      | Notes                                                            |
| --------------------- | ------------------ | --------- | ---------------------------------------------------------------- |
| EC2 t3.Medium         | $0.0416            | $15.00    | On-demand pricing                                                |
| EBS Root (10GB)       | $0.008             | $0.80     | Boot volume                                                      |
| EBS Data (10GB)       | $0.008             | $0.80     | Data volume                                                      |
| S3 Storage (~ 1GB)    | $0.0000315 /GB     | $0.023/GB | Backups (deletes after 3 days)                                   |
| S3 PUT/GET/DELETE ops | negligible         | >$0.01    |                                                                  |
| Elastic IP            | Free-ish or $0.005 |  $1.85    | if not attached to a running instance it will incur cost         |
| Hosted Zone           | -                  | $0.50     | Flat rate of $0.50 per month                                     |

## Prerequisites

- Domain you own
- An AWS Account
  - Hosted Zone
  - Key pair
  - CLI Credentials
- Terraform

#### AWS Account

---

> Note: I won't be taking the time here to instruct how to create an AWS account. If you don't know, you likely should look at other options. This **will cost you money** and jumping into AWS without _some_ knowledge could be costly.

<details>
<summary><b>How to Create an IAM User and Set Up AWS CLI Credentials</b></summary>

> Note: Use the root user to create this IAM user. After that, use your IAM user for the rest of the guide. It is best practice to use your root user for login ONLY. **It is highly recommended that you use MFA for both your ROOT and IAM accounts!**

## Step 1: Create IAM User (AWS Console)

1. Go to the [IAM Dashboard](https://console.aws.amazon.com/iam).
2. In the sidebar, click **Users**, then click **Add users**.
3. Set a **username**, for example: `terraform-user`
4. Select **Access key - Programmatic access** (✅ check this).
5. Click **Next: Permissions**.

## Step 2: Attach Permissions

You can either:

- Attach **existing policies directly**, or
- Add to a group (e.g., `terraform-admin`)

To give full admin (for testing or controlled use):

- Choose **"Attach policies directly"**
- Check **`AdministratorAccess`** (or fine-grained policies if needed)

_This section could use updating to have more finely grained controls. But this will suffice for now. MAKE SURE TO ENABLE MFA._

## Step 3: Download Credentials

1. Click **Next** through remaining steps and **Create user**
2. On the final screen, click **Download .csv** or **copy**:
   - **Access key ID**
   - **Secret access key**

## Step 4: Configure Your Envs Locally (to run TF commands)

On your local machine (install the [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) first if needed) Homebrew works great for MacOS:

Example:

```bash
$ export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
$ export AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
$ export AWS_DEFAULT_REGION=us-west-2
```

</details>

#### Domain You Own

---

You need to own a domain. This can be anything you'd like and you can buy it as cheap as you'd like. I recommend something like [Namecheap](https://www.namecheap.com) or [GoDaddy](https://www.godaddy.com). The [Traefik](https://traefik.io/traefik/) container will issue an x.509 certificate for this domain on first boot.

#### Terraform

---

Terraform is a requirement for this to work as it's the backbone of the infrastructure. You will need to [install it](https://developer.hashicorp.com/terraform/tutorials/aws-get-started/install-cli) and have some understanding of how Terraform works. I recommend going through their [Quickstart Tutorial](https://developer.hashicorp.com/terraform/tutorials/aws-get-started/install-cli#quick-start-tutorial) to get familiarized.

---

## AWS Setup

### How to Set Up a Hosted Zone in AWS

You will need to create a Hosted Zone in Route 53. If you purchase a domain through AWS Route 53 this will be created for you. A hosted zone is not _strictly_ required as you can just assign an A-Record yourself; but for $0.50 per month I decided it's not a huge deal.

#### Steps:

1. Sign in to the [AWS Console](https://console.aws.amazon.com/route53/)
2. Go to **Route 53 > Hosted zones**
3. Click **"Create hosted zone"**
4. Enter the domain name (e.g., `example.com`)
5. Type: **Public hosted zone**
6. Click **"Create hosted zone"**

### Update Domain Registrar (If not using Route 53 for domain registration)

If your domain is **not purchased through Route 53**, update your registrar’s name servers:

1. In Route 53 > Hosted Zone, copy the **NS (Name Server)** values

   - Example:
     ```
     ns-123.awsdns-45.com
     ns-456.awsdns-67.org
     ns-789.awsdns-89.net
     ns-012.awsdns-01.co.uk
     ```

2. Log into your domain registrar (e.g., Namecheap, GoDaddy, etc.)
3. Go to your domain’s **DNS and/or Nameserver settings**
4. Replace the default name servers with the ones from Route 53 (Namecheap you need to set your name server to "custom")
5. Save changes

> **Note:** DNS propagation may take up to 48 hours (usually works within 20-60 min) Use [This DNS Checker](https://dnschecker.org/all-dns-records-of-domain.php) to see if the records have been propagated. The NS records should show your entries.

#### Get Your Hosted Zone ID

1. Go to the [Route 53 Console](https://console.aws.amazon.com/route53/).
2. In the left sidebar, click **"Hosted zones"**.
3. Find the domain name you're working with and click it.
4. Look at the **"Hosted Zone ID"** column next to your domain.

   - It will look something like this:
     ```
     Z39022Z8NSDLKJDSEXAM
     ```

5. Place the ZoneID in the terraformm.tfvars where indicated (`zone_id`)

### Setting up a Key Pair

1. Go to the [EC2 Dashboard](https://console.aws.amazon.com/ec2).
2. In the left sidebar, click **Key Pairs** under **Network & Security**.
3. Click **Create key pair**.
4. Fill out the form:
   - **Name**: `<Pick a name!>` (or any name)
   - **Key pair type**: `RSA`
   - **Private key format**: `PEM` (for OpenSSH)
5. Click **Create key pair**.
6. Your `.pem` file will automatically download. Keep it **safe and secure**.
   - **Do not share this file**
   - **Do not commit it to source control (like GitHub)**

## Terraform Setup

### File Review

**[main.tf](./main.tf)** includes the following which you should review:

```hcl
# Instance Vars
locals {
  instance_type = "t3.medium"
  ami_owner     = "099720109477"
  ami_name      = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
  aws_region    = "us-west-2"
}
```

- `instance_type` can be changed. But in my experience, t3.small would hang upon creating even a single server. I would recommend t3.medium as a minimum.
- `ami_owner` is the canonical owner from the EC2 AMI marketplace
- `ami_name` is the name of the AMI to filter by. ubuntu-jammy-22.04 is a free subscription as of the writing of this doc.
- `aws_region` is the region in which you wish to run your services. I chose us-west-2 as it's located close to me.

**[example_terraform.tfvars](./example_terraform.tfvars)** Should be filled out with your own values. Rename it `terraform.tfvars`. The description of these values is in [variables.tf](./variables.tf).

> Note: The domain should be the FQDN (Fully Qualified Domain Name), meaning if you purchased `mycoolserver.com` you need to add the subdomain you'd like to use, such as: `minecraft.mycoolserver.com`

**[user_data.sh.tpl](./user_data.sh.tpl)** is a template file that runs on first-boot of your instance this _runs once_ when the server is **launched**. It does **not** run on each boot/reboot. However, if you terminate an instance and start a new one it will run again; thus, some checks to ensure data integrity are included.

The tl;dr of this file is that it:

- Checks your EBS is mounted and formatted correctly
- Creates minecraft / traefik directories
- Creates the docker-compose.yml which runs Traefik and Crafty
- Sets up a backup script for your server(s)

The following variables (in terraform.tfvars) are used in this file and must be present for it to work correctly:

- `s3_bucket`
- `admin_email`
- `fqdn`

You can test that this template file compiles correctly by doing the following:

```bash
$ echo 'templatefile("${path.module}/user_data.sh.tpl", {s3_bucket="mybucket-name-here", domain_name="my.server.com", admin_email="my@email.com"})' | terraform console
```

View the output of the template in your terminal and ensure all the variables in the form have been replaced with the values above.

To exit the console:

```bash
$ exit
```

### Running Terraform

At this point all of your variables and required AWS steps should be done. You can now, from your terminal, run:

```bash
$ terraform plan
```

This will output your terraform. Double check the output in your console to ensure it's what is expected. If I remember correctly it should be 18 or 20 some-odd new resources.

If your template and `terraform plan` look correct, you can proceed with:

```bash
$ terraform apply
```

You will be asked for confirmation. Type:

```bash
$ yes
```

This will create your AWS resources. At this point you will begin to incur cost. If anything seems off, you can adjust your variables, template, or main.tf and apply the changes via `terraform apply` again. This will make the necessary modifications.

## Deletion and Cleanup

If you wish to tear down your infrastructure, run:

```bash
$ terraform destroy
```

This will ask for confirmation to delete all resources you deployed. Confirm with

```bash
$ yes
```

This can take some time, especially to remove the VPC.

Remember that after Terraform has destroyed your infrastructure you will still be paying for your Hosted Zone. Remove this hosted zone by going to **"Route 53"** -> **"Hosted Zones"**, click on your domain, and click **"Delete Hosted Zone**"

Optionally, you can remove your key-pair as well by taking similar steps. Key pairs are free, however.
