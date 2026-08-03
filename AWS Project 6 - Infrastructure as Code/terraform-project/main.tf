terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "Terraform-IaC"
      ManagedBy   = "Terraform"
      Environment = var.environment
    }
  }
}

module "vpc" {
  source = "./modules/vpc"

  project_name         = var.project_name
  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  allowed_ssh_cidr     = var.allowed_ssh_cidr
}

module "ec2" {
  source = "./modules/ec2"

  project_name      = var.project_name
  subnet_ids        = module.vpc.public_subnet_ids
  security_group_id = module.vpc.web_sg_id
  instance_type     = var.instance_type
}

module "rds" {
  source = "./modules/rds"

  project_name         = var.project_name
  subnet_ids           = module.vpc.private_subnet_ids
  db_username          = var.db_username
  db_password          = var.db_password
  instance_type        = var.db_instance_type
  db_security_group_id = module.vpc.db_sg_id
}
