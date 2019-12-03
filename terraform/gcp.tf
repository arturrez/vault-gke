terraform {
  backend gcs {
    prefix  = "terraform/infra"
    //    bucket  = "" #these will be passed as backend-config variables in the terraform init. See cloubuild.yaml.
    //    project = ""
  }
}

# This file contains all the interactions with Google Cloud
provider "google" {
  region  = var.region
  project = var.project
}

provider "google-beta" {
  region  = var.region
  project = var.project
}

# Generate a random id for the project - GCP projects must have globally
# unique names
resource "random_id" "project_random" {
  prefix      = var.project_prefix
  byte_length = "8"
}

# Create the project if one isn't specified
resource "google_project" "vault" {
  count           = var.project != "" ? 0 : 1
  name            = random_id.project_random.hex
  project_id      = random_id.project_random.hex
  org_id          = "1"
  billing_account = "1"
}

# Or use an existing project, if defined
data "google_project" "vault" {
  count      = var.project != "" ? 1 : 0
  project_id = var.project
}

# Obtain the project_id from either the newly created project resource or
# existing data project resource One will be populated and the other will be
# null
locals {
  vault_project_id = element(
    concat(
      data.google_project.vault.*.project_id,
      google_project.vault.*.project_id,
    ),
    0,
  )
}

# Create the vault service account
resource "google_service_account" "vault-server" {
  account_id   = "vault-server"
  display_name = "Vault Server"
  project      = local.vault_project_id
}

# Create a service account key
resource "google_service_account_key" "vault" {
  service_account_id = google_service_account.vault-server.name
}

# Add the service account to the project
resource "google_project_iam_member" "service-account" {
  count   = length(var.service_account_iam_roles)
  project = local.vault_project_id
  role    = element(var.service_account_iam_roles, count.index)
  member  = "serviceAccount:${google_service_account.vault-server.email}"
}

# Add user-specified roles
resource "google_project_iam_member" "service-account-custom" {
  count   = length(var.service_account_custom_iam_roles)
  project = local.vault_project_id
  role    = element(var.service_account_custom_iam_roles, count.index)
  member  = "serviceAccount:${google_service_account.vault-server.email}"
}

# Enable required services on the project
resource "google_project_service" "service" {
  count   = length(var.project_services)
  project = local.vault_project_id
  service = element(var.project_services, count.index)

  # Do not disable the service on destroy. On destroy, we are going to
  # destroy the project, but we need the APIs available to destroy the
  # underlying resources.
  disable_on_destroy = false
}

# Create the storage bucket
resource "google_storage_bucket" "vault" {
  name          = "${local.vault_project_id}-vault-storage"
  project       = local.vault_project_id
  force_destroy = true
  storage_class = "MULTI_REGIONAL"

  versioning {
    enabled = true
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }

    condition {
      num_newer_versions = 1
    }
  }

  depends_on = [google_project_service.service]
}

# Grant service account access to the storage bucket
resource "google_storage_bucket_iam_member" "vault-server" {
  count  = length(var.storage_bucket_roles)
  bucket = google_storage_bucket.vault.name
  role   = element(var.storage_bucket_roles, count.index)
  member = "serviceAccount:${google_service_account.vault-server.email}"
}

# Generate a random suffix for the KMS keyring. Like projects, key rings names
# must be globally unique within the project. A key ring also cannot be
# destroyed, so deleting and re-creating a key ring will fail.
#
# This uses a random_id to prevent that from happening.
resource "random_id" "kms_random" {
  prefix      = var.kms_key_ring_prefix
  byte_length = "8"
}

# Obtain the key ring ID or use a randomly generated on.
locals {
  kms_key_ring = var.kms_key_ring != "" ? var.kms_key_ring : random_id.kms_random.hex
}

# Create the KMS key ring
resource "google_kms_key_ring" "vault" {
  name     = local.kms_key_ring
  location = var.region
  project  = local.vault_project_id

  depends_on = [google_project_service.service]
}

# Create the crypto key for encrypting init keys
resource "google_kms_crypto_key" "vault-init" {
  name            = var.kms_crypto_key
  key_ring        = google_kms_key_ring.vault.id
  rotation_period = "604800s"
}

# Grant service account access to the key
resource "google_kms_crypto_key_iam_member" "vault-init" {
  crypto_key_id = google_kms_crypto_key.vault-init.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_service_account.vault-server.email}"
}

# Get latest cluster version
data "google_container_engine_versions" "versions" {
  project  = local.vault_project_id
  location = var.region
}

output "project" {
  value = local.vault_project_id
}

output "region" {
  value = var.region
}

data "google_container_cluster" "main-cluster" {
  name     = "main-cluster"
  location = "us-central1"
}