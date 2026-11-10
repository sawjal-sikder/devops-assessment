environment         = "staging"
aws_region          = "us-east-1"
instance_type       = "t3.micro"
ecr_repository_name = "devops-task"
# Replace the account, digest, and client CIDR before planning.
image              = "123456789012.dkr.ecr.us-east-1.amazonaws.com/devops-task@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
allowed_cidrs      = ["203.0.113.10/32"]
log_retention_days = 7
