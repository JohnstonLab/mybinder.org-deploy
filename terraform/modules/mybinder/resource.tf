provider "google" {
  version = "~> 3.39"
  project = "binderhub-288415"
  region  = "us-central1"
  zone    = "us-central1-a"
}

provider "random" {
  version = "~> 2.3"
}

data "google_client_config" "provider" {}

locals {
  service_accounts = {
    deployer = {
      display_name = "Deployment account for ${var.name}",
      role         = null,
    },
    matomo = {
      display_name = "SQL account for ${var.name} Matomo",
      role         = "roles/cloudsql.client",
    },
    events-archiver = {
      display_name = "Storage access for ${var.name} events archiver",
      role         = "roles/storage.objectAdmin",
    },
    binderhub-builder = {
      display_name = "Storage access for ${var.name} image builder",
      role         = "roles/storage.admin",
    },
  }
  # add -staging to events prefix, but don't include 'prod' in prod events
  events_prefix = var.name == "prod" ? "binder" : "binder-${var.name}"
  # add -staging to events log name, but don't include 'prod' in prod events
  events_log_prefix = var.name == "prod" ? "binderhub" : "binderhub-${var.name}"
}

resource "google_container_cluster" "cluster" {
  name     = var.name
  location = var.gke_location != null ? var.gke_location : data.google_client_config.provider.zone

  min_master_version = var.gke_master_version

  # terraform recommends removing the default node pool
  remove_default_node_pool = true
  initial_node_count       = 1

  network_policy {
    enabled  = true
    provider = "CALICO"
  }

  addons_config {
    network_policy_config {
      disabled = false
    }
  }
}

output "cluster_name" {
  value = google_container_cluster.cluster.name
}

# static ip doesn't work ?!
# have to reserve static ips via cloud console
# resource "google_compute_global_address" "cluster_ip" {
#   name        = var.name
#   description = "public ip for the ${var.name} cluster"
# }

# output "public_ip" {
#   value = google_compute_global_address.cluster_ip.address
# }

resource "google_sql_database_instance" "matomo" {
  name             = "matomo-${var.name}"
  database_version = "MYSQL_5_7"

  settings {
    tier = var.sql_tier
    backup_configuration {
      enabled = true
    }
  }
}

resource "random_id" "sql_root_password" {
  byte_length = 16
}

resource "random_id" "matomo_password" {
  byte_length = 16
}

resource "google_sql_user" "root" {
  name     = "root"
  host     = "%"
  instance = google_sql_database_instance.matomo.name
  password = random_id.sql_root_password.hex
}

resource "google_sql_user" "matomo" {
  name     = "matomo"
  host     = "%"
  instance = google_sql_database_instance.matomo.name
  password = random_id.matomo_password.hex
}

output "matomo_password" {
  value     = google_sql_user.matomo.password
  sensitive = true
}

# CI deployer custom role
resource "google_project_iam_custom_role" "deployer" {
  role_id     = "${var.name}Deployer"
  title       = "${var.name} Deployer"
  description = "Role for deploying to ${var.name} from CI"
  permissions = var.deployer_permissions
}

# create mapping of service accounts
resource "google_service_account" "sa" {
  for_each     = local.service_accounts
  account_id   = "${var.name}-${each.key}"
  display_name = each.value.display_name
}

resource "google_project_iam_member" "iam" {
  for_each = local.service_accounts
  # special-case deployer id
  role   = each.key == "deployer" ? google_project_iam_custom_role.deployer.id : each.value.role
  member = "serviceAccount:${google_service_account.sa[each.key].email}"
}

resource "google_project_iam_member" "deploy-pusher" {
  # deployer also gets storage admin
  role   = "roles/storage.admin"
  member = "serviceAccount:${google_service_account.sa["deployer"].email}"
}

# create keys for each service account
resource "google_service_account_key" "keys" {
  for_each           = local.service_accounts
  service_account_id = google_service_account.sa[each.key].account_id
}

output "private_keys" {
  value = {
    for sa_name in keys(local.service_accounts) :
    sa_name => base64decode(google_service_account_key.keys[sa_name].private_key)
  }
  sensitive = true
}

# create analytics buckets, one for raw-event export, one for the public archive

resource "google_storage_bucket" "archive" {
  name                        = "${local.events_prefix}-events-archive"
  location                    = "US"
  uniform_bucket_level_access = true
}

resource "google_storage_bucket_iam_member" "archive-read-all" {
  bucket = google_storage_bucket.archive.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

resource "google_storage_bucket" "raw-export" {
  name     = "${local.events_prefix}-events-raw-export"
  location = "US"
  # log sync doesn't support uniform access
  # ref: https://cloud.google.com/storage/docs/uniform-bucket-level-access#should-you-use
  uniform_bucket_level_access = false
}

resource "google_logging_project_sink" "events-archive" {
  name        = "binderhub-${var.name}-events-raw-text"
  filter      = "resource.type=\"global\" AND logName=\"projects/${data.google_client_config.provider.project}/logs/${local.events_log_prefix}-events-text\""
  destination = "storage.googleapis.com/${google_storage_bucket.raw-export.name}"
}
