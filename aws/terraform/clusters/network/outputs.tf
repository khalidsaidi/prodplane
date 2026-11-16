output "vpc_id" {
  value = aws_vpc.main_vpc.id
}

output "vpc_cidr" {
  value = aws_vpc.main_vpc.cidr_block
}

output "public_subnet_ids" {
  value = [aws_subnet.public_1.id, aws_subnet.public_2.id]
}

output "private_subnet_ids" {
  value = [aws_subnet.private_1.id, aws_subnet.private_2.id]
}

output "public_subnet_cidrs" {
  value = [for subnet in [aws_subnet.public_1, aws_subnet.public_2] : subnet.cidr_block]
}

output "private_subnet_cidrs" {
  value = [for subnet in [aws_subnet.private_1, aws_subnet.private_2] : subnet.cidr_block]
}

output "internet_gateway_id" {
  value = aws_internet_gateway.igw.id
}

output "public_route_table_id_1" {
  value = aws_route_table.public_1.id
}

output "public_route_table_id_2" {
  value = aws_route_table.public_2.id
}

output "private_route_table_1_id" {
  value = aws_route_table.private_1.id
}

output "private_route_table_2_id" {
  value = aws_route_table.private_2.id
}

output "bastion_sg_id" {
  value = aws_security_group.bastion_sg.id
}
