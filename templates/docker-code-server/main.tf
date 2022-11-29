terraform {
  required_providers {
    coder = {
      source  = "coder/coder"
      version = "0.6.0"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 2.20.2"
    }
  }
}

data "coder_provisioner" "me" {
}

provider "docker" {
}

data "coder_workspace" "me" {
}

variable "repo_uri" {
  description = <<-EOF
  Repository Url
  EOF
  default     = "https://github.com/armandoasd/nextjs-docker.git"
}

resource "coder_agent" "main" {
  arch           = data.coder_provisioner.me.arch
  os             = "linux"
  startup_script = <<EOT
code-server --auth none &
curl -fsSL https://deb.nodesource.com/setup_19.x | sudo -E bash - &&
sudo apt-get update &&
sudo apt-get install -y nodejs &&
git clone ${var.repo_uri} workspace && cd workspace &&
git checkout -b workshop/${data.coder_workspace.me.owner} &&
sudo npm i -g yarn &&
yarn && yarn build

  EOT

  # These environment variables allow you to make Git commits right away after creating a
  # workspace. Note that they take precedence over configuration defined in ~/.gitconfig!
  # You can remove this block if you'd prefer to configure Git manually or using
  # dotfiles. (see docs/dotfiles.md)
  env = {
    GIT_AUTHOR_NAME     = "${data.coder_workspace.me.owner}"
    GIT_COMMITTER_NAME  = "${data.coder_workspace.me.owner}"
    GIT_AUTHOR_EMAIL    = "${data.coder_workspace.me.owner_email}"
    GIT_COMMITTER_EMAIL = "${data.coder_workspace.me.owner_email}"
  }
}

resource "coder_app" "code-server" {
  agent_id     = coder_agent.main.id
  slug         = "workshop-server"
  display_name = "workshop-server"
  url          = "http://localhost:8080/?folder=/home/coder/workspace"
  icon         = "/icon/code.svg"
  subdomain    = false
  share        = "owner"

  healthcheck {
    url       = "http://localhost:8080/healthz"
    interval  = 3
    threshold = 10
  }
}

resource "docker_volume" "home_volume" {
  name = "coder-${data.coder_workspace.me.owner}-${data.coder_workspace.me.name}-root"
}

resource "docker_container" "workspace" {
  count = data.coder_workspace.me.start_count
  image = "codercom/code-server:latest"
  # Uses lower() to avoid Docker restriction on container names.
  name     = "coder-${data.coder_workspace.me.owner}-${lower(data.coder_workspace.me.name)}"
  hostname = lower(data.coder_workspace.me.name)
  dns      = ["1.1.1.1"]
  # Use the docker gateway if the access URL is 127.0.0.1
  entrypoint = ["sh", "-c", replace(coder_agent.main.init_script, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal")]
  env        = ["CODER_AGENT_TOKEN=${coder_agent.main.token}"]
  host {
    host = "host.docker.internal"
    ip   = "host-gateway"
  }
  volumes {
    container_path = "/home/coder/"
    volume_name    = docker_volume.home_volume.name
    read_only      = false
  }
}

resource "coder_metadata" "repo_uri" {
  count       = data.coder_workspace.me.start_count
  resource_id = docker_container.workspace[0].id

  item {
    key   = "repo_uri"
    value = var.repo_uri
  }
}
