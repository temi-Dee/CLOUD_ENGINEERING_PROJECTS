output "web_instance_id" {
  value = aws_instance.web.id
}

output "instance_role_arn" {
  value = aws_iam_role.ec2.arn
}
