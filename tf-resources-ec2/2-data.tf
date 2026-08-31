# Look up an existing VPC to use for our resources
data "aws_vpcs" "available" {}

data "aws_vpc" "selected" {
  id = tolist(data.aws_vpcs.available.ids)[0]
}

data "aws_subnets" "available" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected.id]
  }

  filter {
    name   = "map-public-ip-on-launch"
    values = ["true"]
  }
}
