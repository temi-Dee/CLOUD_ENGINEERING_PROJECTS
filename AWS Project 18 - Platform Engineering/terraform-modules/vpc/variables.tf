variable "name" {
  type        = string
  description = "Name prefix for all VPC resources"
}

variable "cidr_block" {
  type        = string
  description = "CIDR block for the VPC"
  default     = "10.0.0.0/16"
}

variable "environment" {
  type        = string
  description = "Environment name (e.g. production, staging, development)"
}

variable "public_subnets" {
  type        = list(string)
  description = "List of CIDR blocks for public subnets, one per availability zone"
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnets" {
  type        = list(string)
  description = "List of CIDR blocks for private subnets, one per availability zone"
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}
