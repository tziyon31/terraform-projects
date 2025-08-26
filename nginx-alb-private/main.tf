#############################################
# Terraform and Provider setup
#############################################
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
  }
}

# Configure AWS provider region
provider "aws" {
  region = var.region
}

#############################################
# Data sources
#############################################
# Get available AZs in the chosen region
data "aws_availability_zones" "available" {
  state = "available"
}

# Latest Amazon Linux 2023 AMI for app instance
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["137112412989"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

# Latest Amazon Linux 2023 AMI for NAT instance
data "aws_ami" "al2023_nat" {
  most_recent = true
  owners      = ["137112412989"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

#############################################
# Networking: VPC, IGW, Subnets
#############################################
# Create VPC with DNS support and hostnames enabled
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project}-vpc" }
}

# Internet Gateway for public subnets
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-igw" }
}

# Two public subnets (needed for ALB across AZs)
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project}-public-${count.index}", Tier = "public" }
}

# Two private subnets for application instances
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags              = { Name = "${var.project}-private-${count.index}", Tier = "private" }
}

#############################################
# Route Tables
#############################################
# Public route table: default route to Internet Gateway
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-public-rt" }
}

# Default route in public RT points to IGW
resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

# Associate public route table with both public subnets
resource "aws_route_table_association" "public_assoc" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

#############################################
# NAT Instance
#############################################
# SG for NAT instance: allow inbound from VPC and outbound anywhere
resource "aws_security_group" "nat_sg" {
  name        = "${var.project}-nat-sg"
  description = "SG for NAT instance"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Allow from VPC only"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.project}-nat-sg" }
}

# NAT instance with IP forwarding, FORWARD rules, and masquerade
resource "aws_instance" "nat" {
  ami                         = data.aws_ami.al2023_nat.id
  instance_type               = var.nat_instance_type
  subnet_id                   = aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.nat_sg.id]
  associate_public_ip_address = true
  source_dest_check           = false

  user_data = <<-EOF
    #!/bin/bash
    set -eux

    # Enable IP forwarding
    sysctl -w net.ipv4.ip_forward=1
    sed -i 's/^#\\?net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf

    # Install iptables (AL2023 uses iptables-nft)
    dnf -y install iptables

    # Accept forwarding through the box (stateful)
    iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A FORWARD -j ACCEPT

    # SNAT: masquerade outbound via the primary interface (ens5)
    iptables -t nat -A POSTROUTING -o ens5 -j MASQUERADE

    # (Optional) persist rules across reboots
    dnf -y install iptables-services || true
    systemctl enable iptables || true
    service iptables save || true
  EOF

  tags = {
    Name = "${var.project}-nat-instance"
    Role = "nat"
  }
}

# Private route table
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-private-rt" }
}

# Default route in private RT → NAT instance ENI
resource "aws_route" "private_default" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.nat.primary_network_interface_id
  depends_on             = [aws_instance.nat]
}

# Associate private RT with both private subnets
resource "aws_route_table_association" "private_assoc" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

#############################################
# Security Groups for ALB and App
#############################################
# ALB SG: open HTTP port 80 to the world
resource "aws_security_group" "alb_sg" {
  name        = "${var.project}-alb-sg"
  description = "ALB SG open :80"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.project}-alb-sg" }
}

# App SG: allow HTTP only from ALB SG
resource "aws_security_group" "app_sg" {
  name        = "${var.project}-app-sg"
  description = "Allow :80 only from ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "HTTP from ALB only"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.project}-app-sg" }
}

#############################################
# IAM Role and Instance Profile for SSM
#############################################
# Policy document for EC2 to assume role
data "aws_iam_policy_document" "ssm_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# IAM role with AmazonSSMManagedInstanceCore
resource "aws_iam_role" "ssm_role" {
  name               = "${var.project}-ssm-role"
  assume_role_policy = data.aws_iam_policy_document.ssm_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm_profile" {
  name = "${var.project}-ssm-profile"
  role = aws_iam_role.ssm_role.name
}

#############################################
# Private App Instance (EC2 with NGINX in Docker)
#############################################
resource "aws_instance" "app" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.app_instance_type
  subnet_id                   = aws_subnet.private[0].id
  vpc_security_group_ids      = [aws_security_group.app_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.ssm_profile.name
  associate_public_ip_address = false

  user_data = <<-EOF
              #!/bin/bash
              set -eux
              dnf update -y
              dnf install -y docker
              systemctl enable --now docker
              mkdir -p /usr/share/nginx/html
              echo "yo this is nginx" > /usr/share/nginx/html/index.html
              docker run -d --name web -p 80:80 -v /usr/share/nginx/html:/usr/share/nginx/html:ro nginx:stable
              EOF

  tags = { Name = "${var.project}-app" }
}

#############################################
# Application Load Balancer, Target Group, Listener
#############################################
resource "aws_lb" "app_alb" {
  name               = "${var.project}-alb"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.public[0].id, aws_subnet.public[1].id]
  idle_timeout       = 60
  tags               = { Name = "${var.project}-alb" }
}

resource "aws_lb_target_group" "tg" {
  name        = "${var.project}-tg"
  port        = 80
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = aws_vpc.main.id

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 10
    path                = "/"
    matcher             = "200-399"
  }
  tags = { Name = "${var.project}-tg" }
}

resource "aws_lb_target_group_attachment" "tg_att" {
  target_group_arn = aws_lb_target_group.tg.arn
  target_id        = aws_instance.app.id
  port             = 80
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app_alb.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

#############################################
# Outputs
#############################################
output "alb_dns_name" {
  description = "Public URL of the ALB"
  value       = aws_lb.app_alb.dns_name
}

output "app_private_ip" {
  description = "Private IP of the EC2 app instance"
  value       = aws_instance.app.private_ip
}

