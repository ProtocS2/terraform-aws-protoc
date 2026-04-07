provider "aws" {
  region = var.aws_region
}


data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "zone-type"
    values = ["availability-zone"]
  }
}

data "aws_region" "current" { }

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

resource "aws_instance" "app_server" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  user_data_base64       = filebase64("user-data.sh")
  vpc_security_group_ids = [module.app_security_group.security_group_id]
  subnet_id              = module.vpc.private_subnets[0]

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = var.instance_name
  }
}


resource "aws_launch_template" "protoc" {
  name_prefix   = "protoc-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = var.instance_type
  user_data = filebase64("user-data.sh")
  vpc_security_group_ids = [module.app_security_group.security_group_id]
}

resource "aws_autoscaling_group" "protoc" {
  name                 = "protoc"
  min_size             = 1
  max_size             = 3
  desired_capacity     = 1
  launch_template  {
  id      = aws_launch_template.protoc.id
  version = "$Latest"
  }
  vpc_zone_identifier  = module.vpc.public_subnets

  health_check_type    = "ELB"

  tag {
    key                 = "Name"
    value               = "Protoc"
    propagate_at_launch = true
  }
}

resource "aws_lb" "protoc" {
  name               = "protoc-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.lb.id]
  subnets            = module.vpc.public_subnets
}

resource "aws_lb_listener" "protoc" {
  load_balancer_arn = aws_lb.protoc.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.protoc.arn
  }
}

resource "aws_lb_target_group" "protoc" {
  name     = "learn-asg-protoc"
  port     = 80
  protocol = "HTTP"
  vpc_id   = module.vpc.vpc_id
}


resource "aws_autoscaling_attachment" "protoc" {
  autoscaling_group_name = aws_autoscaling_group.protoc.id
  lb_target_group_arn   = aws_lb_target_group.protoc.arn
}


module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.6.0"

  name = "protoc-vpc"
  cidr = var.vpc_cidr_block

  azs             = data.aws_availability_zones.available.names
  private_subnets = slice(var.private_subnet_cidr_blocks, 0, 2)
  public_subnets  = slice(var.public_subnet_cidr_blocks, 0, 2)

  enable_dns_hostnames = true
  enable_dns_support = true
  enable_nat_gateway = true
  enable_vpn_gateway = false

  map_public_ip_on_launch = false
}
module "app_security_group" {
  source  = "terraform-aws-modules/security-group/aws//modules/web"
  version = "4.9.0"

  name        = "web-server-sg"
  description = "Security group for web-servers with HTTP ports open within VPC"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks = module.vpc.public_subnets_cidr_blocks
}

resource "aws_security_group" "lb" {
  name        = "protoc-lb-sg"
  description = "Security group for load balancer"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "protoc-lb-sg"
  }
}

resource "aws_security_group" "rds" {
  name   = "protoc_rds"
  vpc_id = module.vpc.vpc_id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "protoc_rds"
  }
}

resource "aws_db_parameter_group" "protoc-vpc" {
  name   = "protoc"
  family = "postgres18"

  parameter {
    name  = "log_connections"
    value = "all"
  }
}

resource "aws_db_subnet_group" "protoc" {
  name       = "protoc"
  subnet_ids = module.vpc.private_subnets

  tags = {
    Name = "protoc"
  }
}

resource "aws_db_instance" "protoc-vpc" {
  identifier             = "protoc"
  instance_class         = "db.t3.micro"
  allocated_storage      = 10
  backup_retention_period = 1
  apply_immediately      = true
  engine                 = "postgres"
  engine_version         = "18.3"
  username               = "edu"
  password               = var.db_password
  db_subnet_group_name   = aws_db_subnet_group.protoc.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.protoc-vpc.name
  publicly_accessible    = true
  skip_final_snapshot    = true
}

resource "aws_db_instance" "protoc_replica" {
   identifier             = "protoc-replica"
   replicate_source_db    = aws_db_instance.protoc-vpc.identifier
   instance_class         = "db.t3.micro"
   apply_immediately      = true
   publicly_accessible    = true
   skip_final_snapshot    = true
   vpc_security_group_ids = [aws_security_group.rds.id]
   parameter_group_name   = aws_db_parameter_group.protoc-vpc.name
}

resource "random_pet" "pet_name" {
  length    = 3
  separator = "-"
}

resource "aws_iam_user" "new_user" {
  name = "new_user"
}

resource "aws_s3_bucket" "bucket" {
  bucket = "${random_pet.pet_name.id}-bucket"

  tags = {
    Name        = "My bucket"
    Environment = "Dev"
  }
}

resource "aws_iam_policy" "policy" {
  name        = "${random_pet.pet_name.id}-policy"
  description = "My test policy"
  policy = data.aws_iam_policy_document.example.json
}

data "aws_iam_policy_document" "example" {
  statement {
    actions   = ["s3:ListAllMyBuckets"]
    resources = ["arn:aws:s3:::*"]
    effect = "Allow"
  }
  statement {
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.bucket.arn]
    effect = "Allow"
  }
}

resource "aws_iam_user_policy_attachment" "attachment" {
  user       = aws_iam_user.new_user.name
  policy_arn = aws_iam_policy.policy.arn
}





