locals {
  peer_region          = var.peering == null ? var.aws_region : coalesce(var.peering.region, var.aws_region)
  cross_region_peering = local.peer_region != var.aws_region
  private_peering_routes = var.peering == null ? {} : {
    private_1 = aws_route_table.private_1.id
    private_2 = aws_route_table.private_2.id
  }
}
resource "aws_vpc_peering_connection" "peer" {
  count         = var.peering == null ? 0 : 1
  provider      = aws.default
  vpc_id        = aws_vpc.main_vpc.id
  peer_vpc_id   = var.peering.vpc_id
  peer_owner_id = data.aws_caller_identity.platform_account.account_id
  peer_region   = local.cross_region_peering ? local.peer_region : null
  auto_accept   = !local.cross_region_peering
  tags          = { Name = "${var.project_name}-${var.cluster_environment}-peering" }
}
resource "aws_vpc_peering_connection_accepter" "peer" {
  count                     = var.peering != null && local.cross_region_peering ? 1 : 0
  provider                  = aws.peer
  vpc_peering_connection_id = aws_vpc_peering_connection.peer[0].id
  auto_accept               = true
}
resource "aws_route" "to_peer_private" {
  for_each                  = local.private_peering_routes
  route_table_id            = each.value
  destination_cidr_block    = var.peering.cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.peer[0].id
  depends_on                = [aws_vpc_peering_connection_accepter.peer]
}
resource "aws_route" "from_peer" {
  count                     = var.peering == null ? 0 : 1
  provider                  = aws.peer
  route_table_id            = var.peering.route_table_id
  destination_cidr_block    = aws_vpc.main_vpc.cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.peer[0].id
  depends_on                = [aws_vpc_peering_connection_accepter.peer]
}
