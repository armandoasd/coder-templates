terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "0.6.0"
    }
    google = {
      source  = "hashicorp/google"
      version = "~> 4.34.0"
    }
  }
}

variable "project_id" {
  description = "Which Google Compute Project should your workspace live in?"
  default = "tralevo"
}

variable "zone" {
  description = "What region should your workspace live in?"
  default     = "europe-central2-a"
  validation {
    condition     = contains(["northamerica-northeast1-a", "us-central1-a", "us-west2-c", "europe-west4-b","europe-central2-a", "southamerica-east1-a"], var.zone)
    error_message = "Invalid zone!"
  }
}

variable "machine_type" {
  description = "What Kind of machine do you wan to allocate"
  default     = "e2-small"
  validation {
    condition     = contains(["e2-medium", "e2-small", "e2-micro"], var.machine_type)
    error_message = "Invalid Machine!"
  }
}

variable "repo_uri" {
  description = <<-EOF
  Repository Url
  EOF
  default     = "https://github.com/armandoasd/nextjs-docker.git"
}

provider "google" {
  zone    = var.zone
  project = var.project_id
}

data "google_compute_default_service_account" "default" {
}

data "coder_workspace" "me" {
}

resource "google_compute_disk" "root" {
  name  = "coder-${lower(data.coder_workspace.me.owner)}-${lower(data.coder_workspace.me.name)}-root"
  type  = "pd-ssd"
  zone  = var.zone
  image = "debian-cloud/debian-11"
  lifecycle {
    ignore_changes = [image]
  }
}

resource "coder_agent" "main" {
  auth           = "google-instance-identity"
  arch           = "amd64"
  os             = "linux"
  startup_script = <<EOT
    #!/bin/bash

    # install and start code-server
    curl -fsSL https://code-server.dev/install.sh | sh  | tee code-server-install.log
    git clone ${var.repo_uri} workspace && cd workspace
    git checkout -b workshop/${data.coder_workspace.me.owner}
    sudo npm i -g yarn
    yarn && yarn build
    code-server --auth none --port 13337 ./workspace | tee code-server-install.log &
  EOT
}

# code-server
resource "coder_app" "code-server" {
  agent_id     = coder_agent.main.id
  slug         = "code-server"
  display_name = "code-server"
  icon         = "/icon/code.svg"
  url          = "http://localhost:13337?folder=/home/coder"
  subdomain    = false
  share        = "owner"

  healthcheck {
    url       = "http://localhost:13337/healthz"
    interval  = 3
    threshold = 10
  }
}

resource "google_compute_instance" "dev" {
  zone         = var.zone
  count        = data.coder_workspace.me.start_count
  name         = "coder-${lower(data.coder_workspace.me.owner)}-${lower(data.coder_workspace.me.name)}-root"
  machine_type = var.machine_type
  network_interface {
    network = "default"
    access_config {
      // Ephemeral public IP
    }
  }
  boot_disk {
    auto_delete = false
    source      = google_compute_disk.root.name
  }
  service_account {
    email  = data.google_compute_default_service_account.default.email
    scopes = ["cloud-platform"]
  }
  # The startup script runs as root with no $HOME environment set up, so instead of directly
  # running the agent init script, create a user (with a homedir, default shell and sudo
  # permissions) and execute the init script as that user.
  metadata_startup_script = <<EOMETA
#!/usr/bin/env sh
set -eux

# If user does not exist, create it and set up passwordless sudo
if ! id -u "${local.linux_user}" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "${local.linux_user}"
  echo "${local.linux_user} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/coder-user
fi

# install PreRequizites

curl -fsSL https://deb.nodesource.com/setup_19.x | sudo -E bash -
sudo apt-get update
sudo apt-get install -y nodejs git

exec sudo -u "${local.linux_user}" sh -c '${coder_agent.main.init_script}'
EOMETA
}

locals {
  # Ensure Coder username is a valid Linux username
  linux_user = lower(substr(data.coder_workspace.me.owner, 0, 32))
}

resource "coder_metadata" "workspace_info" {
  count       = data.coder_workspace.me.start_count
  resource_id = google_compute_instance.dev[0].id

  item {
    key   = "type"
    value = google_compute_instance.dev[0].machine_type
  }
}

resource "coder_metadata" "home_info" {
  resource_id = google_compute_disk.root.id

  item {
    key   = "size"
    value = "${google_compute_disk.root.size} GiB"
  }
}
