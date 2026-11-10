# Offline plan assertions only. These tests do not apply resources or prove AWS access.
mock_provider "aws" {
  # IAM policy-document data sources are local JSON transforms, not AWS calls.
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  override_data {
    target = data.aws_availability_zones.available
    values = { names = ["us-east-1a"] }
  }
  override_data {
    target = data.aws_ssm_parameter.ami
    values = { value = "ami-0123456789abcdef0" }
  }
  override_data {
    target = data.aws_ecr_repository.app
    values = {
      arn            = "arn:aws:ecr:us-east-1:123456789012:repository/devops-task"
      repository_url = "123456789012.dkr.ecr.us-east-1.amazonaws.com/devops-task"
    }
  }
}

variables {
  environment   = "staging"
  image         = "123456789012.dkr.ecr.us-east-1.amazonaws.com/devops-task@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  allowed_cidrs = ["203.0.113.10/32"]
}

run "staging_security_and_logging" {
  command = plan
  assert {
    condition     = aws_instance.app.metadata_options[0].http_tokens == "required"
    error_message = "EC2 must require IMDSv2."
  }
  assert {
    condition     = aws_instance.app.root_block_device[0].encrypted
    error_message = "Root storage must be encrypted."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.app["203.0.113.10/32"].from_port == 8080 && aws_vpc_security_group_ingress_rule.app["203.0.113.10/32"].to_port == 8080
    error_message = "The only ingress port must be 8080."
  }
  assert {
    condition     = aws_cloudwatch_log_group.app.retention_in_days == 14
    error_message = "Logs must have bounded retention."
  }
  assert {
    condition     = strcontains(aws_instance.app.user_data, "awslogs-create-group") && strcontains(aws_instance.app.user_data, "devops-bootstrap.service")
    error_message = "Bootstrap must install the app and configure CloudWatch logging."
  }
}

run "production_environment" {
  command = plan
  variables {
    environment        = "production"
    log_retention_days = 30
  }
  assert {
    condition     = aws_cloudwatch_log_group.app.name == "/devops-task/production/app" && aws_cloudwatch_log_group.app.retention_in_days == 30
    error_message = "Production must use its own log group and configured retention."
  }
}

run "reject_public_ingress" {
  command = plan
  variables { allowed_cidrs = ["0.0.0.0/0"] }
  expect_failures = [var.allowed_cidrs]
}

run "reject_mutable_image" {
  command = plan
  variables { image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/devops-task:latest" }
  expect_failures = [var.image]
}
