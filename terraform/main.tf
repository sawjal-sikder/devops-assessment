locals {
  name = "devops-task-${var.environment}"
}

data "aws_availability_zones" "available" { state = "available" }
data "aws_ecr_repository" "app" { name = var.ecr_repository_name }
data "aws_ssm_parameter" "ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_vpc" "app" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = local.name }
}

resource "aws_subnet" "app" {
  vpc_id                  = aws_vpc.app.id
  cidr_block              = var.subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = local.name }
}

resource "aws_internet_gateway" "app" { vpc_id = aws_vpc.app.id }
resource "aws_route_table" "app" {
  vpc_id = aws_vpc.app.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.app.id
  }
}
resource "aws_route_table_association" "app" {
  subnet_id      = aws_subnet.app.id
  route_table_id = aws_route_table.app.id
}

resource "aws_security_group" "app" {
  name_prefix = "${local.name}-"
  description = "Application clients only; administration uses SSM, no SSH"
  vpc_id      = aws_vpc.app.id
}
resource "aws_vpc_security_group_ingress_rule" "app" {
  for_each          = toset(var.allowed_cidrs)
  security_group_id = aws_security_group.app.id
  description       = "Application HTTP from an approved client network"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 8080
  to_port           = 8080
}
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS for packages, ECR, S3 layers, SSM and CloudWatch"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/devops-task/${var.environment}/app"
  retention_in_days = var.log_retention_days
}

data "aws_iam_policy_document" "assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "app" {
  name               = local.name
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
}

data "aws_iam_policy_document" "app" {
  statement {
    sid       = "ECRLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # AWS does not support repository scoping for this action.
  }
  statement {
    sid       = "PullOnlyThisRepository"
    actions   = ["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"]
    resources = [data.aws_ecr_repository.app.arn]
  }
  statement {
    sid       = "WriteOnlyApplicationLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.app.arn}:*"]
  }
  statement {
    sid       = "SSMManagedNodeRegistration"
    actions   = ["ssm:UpdateInstanceInformation"]
    resources = ["*"] # Managed-node registration is not resource scoped.
  }
  statement {
    sid = "SSMCommandChannels"
    actions = [
      "ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel"
    ]
    resources = ["*"] # Channel APIs do not support resource scoping.
  }
}
resource "aws_iam_role_policy" "app" {
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.app.json
}
resource "aws_iam_instance_profile" "app" { role = aws_iam_role.app.name }

resource "aws_instance" "app" {
  ami                         = data.aws_ssm_parameter.ami.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.app.id
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = aws_iam_instance_profile.app.name
  associate_public_ip_address = true
  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/bootstrap.sh.tftpl", {
    image       = var.image
    region      = var.aws_region
    environment = var.environment
    log_group   = aws_cloudwatch_log_group.app.name
    registry    = split("/", var.image)[0]
  })
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  root_block_device {
    volume_size           = 8
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }
  lifecycle {
    precondition {
      condition     = startswith(var.image, "${data.aws_ecr_repository.app.repository_url}@")
      error_message = "image must belong to ecr_repository_name in this AWS account/region."
    }
  }
  depends_on = [aws_route_table_association.app, aws_iam_role_policy.app, aws_vpc_security_group_egress_rule.https]
  tags       = { Name = local.name }
}
