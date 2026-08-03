output "vpc_id" {
  description = "Created VPC ID"
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "IDs of public subnets"
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "IDs of private subnets"
  value       = module.vpc.private_subnet_ids
}

output "web_security_group_id" {
  description = "Web server security group ID"
  value       = module.vpc.web_sg_id
}

output "web_instance_id" {
  description = "Web server EC2 instance ID"
  value       = module.ec2.web_instance_id
}

output "db_instance_endpoint" {
  description = "RDS database endpoint"
  value       = module.rds.db_instance_endpoint
  sensitive   = true
}
