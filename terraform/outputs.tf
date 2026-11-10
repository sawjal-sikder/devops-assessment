output "instance_id" {
  description = "Set GitHub production variable EC2_INSTANCE_ID to this value."
  value       = aws_instance.app.id
}
output "health_url" {
  value = "http://${aws_instance.app.public_ip}:8080/health"
}
output "log_group" { value = aws_cloudwatch_log_group.app.name }
output "vpc_id" { value = aws_vpc.app.id }
output "ecr_repository_url" { value = data.aws_ecr_repository.app.repository_url }
