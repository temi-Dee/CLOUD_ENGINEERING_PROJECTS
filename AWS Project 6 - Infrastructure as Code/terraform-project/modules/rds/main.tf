resource "aws_db_subnet_group" "rds" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = var.subnet_ids

  tags = {
    Name = "${var.project_name}-db-subnet-group"
  }
}

resource "aws_db_instance" "main" {
  identifier                = "${var.project_name}-db"
  allocated_storage         = 20
  engine                    = "postgres"
  engine_version            = "15"
  instance_class            = var.instance_type
  db_name                   = "mydb"
  username                  = var.db_username
  password                  = var.db_password
  publicly_accessible       = false
  db_subnet_group_name      = aws_db_subnet_group.rds.name
  vpc_security_group_ids    = [var.db_security_group_id]
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.project_name}-final-snapshot"
  deletion_protection       = true
  storage_encrypted         = true

  tags = {
    Name = "${var.project_name}-db"
  }
}
