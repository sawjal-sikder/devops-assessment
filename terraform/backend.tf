# Supply bucket, key, and region through -backend-config; never credentials.
terraform {
  backend "s3" {
    encrypt      = true
    use_lockfile = true
  }
}
