variable "fqdn" {
  description = "The fully-qualified domain (which you should own) for the Minecraft server (e.g., minecraft.mycoolserver.com)"
  type        = string
}

variable "s3_bucket" {
  description = "S3 bucket name for backups (must be unique to all of AWS, not just your account)"
  type        = string
}

variable "my_ip" {
  description = "Your public IP address in CIDR notation (e.g., 203.0.113.0/24) https://www.calculator.net/ip-subnet-calculator.html should give you the IP + netmask in the calculator field (netmask is above)"
  type        = string
}

variable "admin_email" {
  description = "The email address for let's encrypt"
  type        = string
}

variable "key_name" {
  description = "The name of the SSH key pair for EC2 access"
  type        = string
}

variable "zone_id" {
  description = "The ID of your AWS Hosted Zone found in the Hosted Zone settings"
  type        = string
}
