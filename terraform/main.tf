provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = local.project
      Env       = local.env
      ManagedBy = "terraform"
      Repo      = "cpt-infra"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  project    = "cpt"
  env        = "prod"
  ssm_prefix = "/cpt/prod"
  account_id = data.aws_caller_identity.current.account_id
}
