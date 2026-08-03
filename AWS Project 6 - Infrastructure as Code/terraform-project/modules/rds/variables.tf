variable "project_name" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "db_username" {
  type = string
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "instance_type" {
  type = string
}

variable "db_security_group_id" {
  type = string
}
