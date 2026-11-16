# VPC
resource "aws_vpc" "main_vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.cluster_environment}-vpc"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main_vpc.id
  tags = {
    Name = "${var.cluster_environment}-igw"
  }
}

resource "aws_eip" "nat_1" {
  domain = "vpc"
  tags = {
    Name = "${var.cluster_environment}-eip-1"
  }
}

resource "aws_eip" "nat_2" {
  domain = "vpc"
  tags = {
    Name = "${var.cluster_environment}-eip-2"
  }
}

resource "aws_nat_gateway" "nat_1" {
  allocation_id = aws_eip.nat_1.id
  subnet_id     = aws_subnet.public_1.id
  depends_on    = [aws_internet_gateway.igw, aws_subnet.public_1, aws_subnet.public_2]

  tags = {
    Name = "${var.cluster_environment}-nat-gateway-1"
  }
}

resource "aws_nat_gateway" "nat_2" {
  allocation_id = aws_eip.nat_2.id
  subnet_id     = aws_subnet.public_2.id
  depends_on    = [aws_internet_gateway.igw, aws_subnet.public_1, aws_subnet.public_2]

  tags = {
    Name = "${var.cluster_environment}-nat-gateway-2"
  }
}

resource "aws_subnet" "public_1" {
  vpc_id                  = aws_vpc.main_vpc.id
  cidr_block              = var.public_subnet_cidrs[0]
  availability_zone       = var.availability_zones[0]
  map_public_ip_on_launch = true
  tags = {
    Name                                                                           = "${var.cluster_environment}-public-subnet-1"
    "kubernetes.io/role/elb"                                                       = "1"
    "kubernetes.io/cluster/${var.project_name}-${var.cluster_environment}-cluster" = "shared"
  }
}

resource "aws_subnet" "public_2" {
  vpc_id                  = aws_vpc.main_vpc.id
  cidr_block              = var.public_subnet_cidrs[1]
  availability_zone       = var.availability_zones[1]
  map_public_ip_on_launch = true
  tags = {
    Name                                                                           = "${var.cluster_environment}-public-subnet-2"
    "kubernetes.io/role/elb"                                                       = "1"
    "kubernetes.io/cluster/${var.project_name}-${var.cluster_environment}-cluster" = "shared"
  }
}

resource "aws_subnet" "private_1" {
  vpc_id            = aws_vpc.main_vpc.id
  cidr_block        = var.private_subnet_cidrs[0]
  availability_zone = var.availability_zones[0]
  tags = {
    Name                                                                           = "${var.cluster_environment}-private-subnet-1"
    "kubernetes.io/role/internal-elb"                                              = "1"
    "kubernetes.io/cluster/${var.project_name}-${var.cluster_environment}-cluster" = "shared"
  }
}

resource "aws_subnet" "private_2" {
  vpc_id            = aws_vpc.main_vpc.id
  cidr_block        = var.private_subnet_cidrs[1]
  availability_zone = var.availability_zones[1]
  tags = {
    Name                                                                           = "${var.cluster_environment}-private-subnet-2"
    "kubernetes.io/role/internal-elb"                                              = "1"
    "kubernetes.io/cluster/${var.project_name}-${var.cluster_environment}-cluster" = "shared"
  }
}

# Public route tables
resource "aws_route_table" "public_1" {
  vpc_id = aws_vpc.main_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  # Inline route tables must own all their routes; standalone peering
  # resources on the same table would be overwritten by later applies.
  dynamic "route" {
    for_each = var.peering == null ? [] : [var.peering]
    content {
      cidr_block                = route.value.cidr
      vpc_peering_connection_id = aws_vpc_peering_connection.peer[0].id
    }
  }
  tags = {
    Name = "${var.cluster_environment}-public-route-table-1"
  }
  depends_on = [aws_nat_gateway.nat_1, aws_nat_gateway.nat_2, aws_vpc_peering_connection_accepter.peer]
}

resource "aws_route_table" "public_2" {
  vpc_id = aws_vpc.main_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  # Inline route tables must own all their routes; standalone peering
  # resources on the same table would be overwritten by later applies.
  dynamic "route" {
    for_each = var.peering == null ? [] : [var.peering]
    content {
      cidr_block                = route.value.cidr
      vpc_peering_connection_id = aws_vpc_peering_connection.peer[0].id
    }
  }
  tags = {
    Name = "${var.cluster_environment}-public-route-table-2"
  }
  depends_on = [aws_nat_gateway.nat_1, aws_nat_gateway.nat_2, aws_vpc_peering_connection_accepter.peer]
}

resource "aws_route_table_association" "public_association_1" {
  subnet_id      = aws_subnet.public_1.id
  route_table_id = aws_route_table.public_1.id
}

resource "aws_route_table_association" "public_association_2" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public_2.id
}




# Private route tables
resource "aws_route_table" "private_1" {
  vpc_id = aws_vpc.main_vpc.id
  tags = {
    Name = "${var.cluster_environment}-private-route-table-1"
  }
  depends_on = [aws_nat_gateway.nat_1, aws_nat_gateway.nat_2]
}

resource "aws_route_table" "private_2" {
  vpc_id = aws_vpc.main_vpc.id
  tags = {
    Name = "${var.cluster_environment}-private-route-table-2"
  }
  depends_on = [aws_nat_gateway.nat_1, aws_nat_gateway.nat_2]
}

resource "aws_route" "private_route_1" {
  route_table_id         = aws_route_table.private_1.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat_1.id
}

resource "aws_route" "private_route_2" {
  route_table_id         = aws_route_table.private_2.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat_2.id
}

resource "aws_route_table_association" "private_association_1" {
  subnet_id      = aws_subnet.private_1.id
  route_table_id = aws_route_table.private_1.id
}

resource "aws_route_table_association" "private_association_2" {
  subnet_id      = aws_subnet.private_2.id
  route_table_id = aws_route_table.private_2.id
}
