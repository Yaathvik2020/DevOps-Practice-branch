# Look up an existing VPC to use for our resources
data "aws_vpcs" "available" {}

data "aws_vpc" "selected" {
  id = tolist(data.aws_vpcs.available.ids)[0]
}
