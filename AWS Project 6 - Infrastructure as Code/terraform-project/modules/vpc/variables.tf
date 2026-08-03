variable "project_name" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "availability_zones" {
  type = list(string)
}

variable "public_subnet_cidrs" {
  type = list(string)
}

variable "private_subnet_cidrs" {
  type = list(string)
}

variable "allowed_ssh_cidr" {
  type        = string
  description = "CIDR block permitted to SSH into web servers — must be set explicitly (e.g. your office IP /32)"
}
