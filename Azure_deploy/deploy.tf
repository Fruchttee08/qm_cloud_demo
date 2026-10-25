terraform {
  required_version = ">= 1.11.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.62"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"          # ephemeral random_password
    }
  }
}

provider "azurerm" {
  # subscription_id = "<SUBSCRIPTION-ID>"  # oder ARM_SUBSCRIPTION_ID

  features {
    key_vault {
      purge_soft_delete_on_destroy          = true
      recover_soft_deleted_key_vaults       = true
      purge_soft_deleted_secrets_on_destroy = true
      recover_soft_deleted_secrets          = true
    }
  }
}

# ======================= Variablen =======================

variable "location" {
  type    = string
  default = "francecentral"
}

variable "resource_group_name" {
  type    = string
  default = "rg-qm-cloud-demo"
}

variable "service_plan_name" {
  type    = string
  default = "asp-qm-cloud-demo"
}

variable "web_app_name" {
  type    = string
  default = "qm-cloud-demo"
}

variable "github_owner" {
  type    = string
  default = "Fruchttee08"
}

variable "github_repo_name" {
  type    = string
  default = "qm_cloud_demo"
}

variable "github_branch" {
  type    = string
  default = "master"
}

variable "key_vault_name" {
  description = "Global eindeutig, 3-24 Zeichen, nur a-z, 0-9, -"
  type        = string
  default     = "kv-qm-cloud-demo"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9-]{1,22}[a-zA-Z0-9]$", var.key_vault_name)) && !strcontains(var.key_vault_name, "--")
    error_message = "Key-Vault-Name: 3-24 Zeichen, beginnt mit Buchstabe, endet mit Buchstabe/Ziffer, keine doppelten Bindestriche."
  }
}

variable "django_secret_value" {
  description = "Django SECRET_KEY (wird NICHT im State gespeichert)"
  type        = string
  sensitive   = true
  ephemeral   = true

  validation {
    condition     = length(var.django_secret_value) >= 16
    error_message = "Der Django SECRET_KEY sollte mindestens 16 Zeichen lang sein."
  }
}

variable "django_secret_version" {
  description = "Erhöhen, um einen neuen SECRET_KEY in den Key Vault zu schreiben"
  type        = number
  default     = 1
}

# ---- Netzwerk ----

variable "vnet_address_space" {
  type    = string
  default = "10.20.0.0/16"
}

variable "subnet_app_prefix" {
  type    = string
  default = "10.20.1.0/24"
}

variable "subnet_mysql_prefix" {
  type    = string
  default = "10.20.2.0/24"
}

variable "subnet_pe_prefix" {
  type    = string
  default = "10.20.3.0/24"
}

variable "deployer_ip" {
  description = "Öffentliche IP des Rechners, der Terraform ausführt (für Key-Vault-Firewall), z. B. 203.0.113.10"
  type        = string
}

# ---- MySQL ----

variable "mysql_server_name" {
  description = "Global eindeutig, 3-63 Zeichen, Kleinbuchstaben, Ziffern, -"
  type        = string
  default     = "mysql-qm-cloud-demo"
}

variable "mysql_admin_login" {
  type    = string
  default = "djangoadmin"
}

variable "mysql_database_name" {
  type    = string
  default = "django"
}

variable "mysql_sku" {
  type    = string
  default = "B_Standard_B1ms"
}

variable "mysql_password_version" {
  description = "Erhöhen, um ein neues MySQL-Passwort zu erzeugen (MySQL + Key Vault werden gemeinsam aktualisiert)"
  type        = number
  default     = 1
}

# ======================= Basis =======================

data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
}

resource "azurerm_service_plan" "main" {
  name                = var.service_plan_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  os_type             = "Linux"
  sku_name            = "B1"   # Basic unterstützt VNet-Integration
}

# ======================= Netzwerk =======================

resource "azurerm_virtual_network" "main" {
  name                = "vnet-${var.web_app_name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = [var.vnet_address_space]
}

# Subnetz für die VNet-Integration der Web App
resource "azurerm_subnet" "app" {
  name                 = "snet-app"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.subnet_app_prefix]

  delegation {
    name = "appservice"
    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

# Subnetz für MySQL Flexible Server (Private Access)
resource "azurerm_subnet" "mysql" {
  name                 = "snet-mysql"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.subnet_mysql_prefix]

  delegation {
    name = "mysqlfs"
    service_delegation {
      name    = "Microsoft.DBforMySQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# Subnetz für Private Endpoints (Key Vault)
resource "azurerm_subnet" "pe" {
  name                              = "snet-pe"
  resource_group_name               = azurerm_resource_group.main.name
  virtual_network_name              = azurerm_virtual_network.main.name
  address_prefixes                  = [var.subnet_pe_prefix]
  private_endpoint_network_policies = "Disabled"
}

# ---- Private DNS: Key Vault ----

resource "azurerm_private_dns_zone" "kv" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "kv" {
  name                  = "link-kv"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.kv.name
  virtual_network_id    = azurerm_virtual_network.main.id
}

# ---- Private DNS: MySQL ----

resource "azurerm_private_dns_zone" "mysql" {
  name                = "${var.mysql_server_name}.private.mysql.database.azure.com"
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "mysql" {
  name                  = "link-mysql"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.mysql.name
  virtual_network_id    = azurerm_virtual_network.main.id
}

# ======================= Identität =======================

resource "azurerm_user_assigned_identity" "app" {
  name                = "id-${var.web_app_name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}

# ======================= Key Vault =======================

resource "azurerm_key_vault" "main" {
  name                       = var.key_vault_name
  location                   = azurerm_resource_group.main.location
  resource_group_name        = azurerm_resource_group.main.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  purge_protection_enabled   = false
  rbac_authorization_enabled = true   # bei "Unsupported argument": enable_rbac_authorization = true

  # Öffentlich nur für die Deployer-IP, App greift über Private Endpoint zu
  public_network_access_enabled = true

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
    ip_rules       = [var.deployer_ip]
  }
}

resource "azurerm_private_endpoint" "kv" {
  name                = "pe-${var.key_vault_name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.pe.id

  private_service_connection {
    name                           = "psc-kv"
    private_connection_resource_id = azurerm_key_vault.main.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "kv-dns"
    private_dns_zone_ids = [azurerm_private_dns_zone.kv.id]
  }
}

resource "azurerm_role_assignment" "deployer_secrets_officer" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "app_secrets_user" {
  scope                            = azurerm_key_vault.main.id
  role_definition_name             = "Key Vault Secrets User"
  principal_id                     = azurerm_user_assigned_identity.app.principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

resource "time_sleep" "wait_for_rbac" {
  create_duration = "120s"

  depends_on = [
    azurerm_role_assignment.deployer_secrets_officer,
    azurerm_role_assignment.app_secrets_user,
  ]
}

# ======================= MySQL =======================

# Wird pro Lauf neu erzeugt, aber nur angewendet, wenn mysql_password_version steigt.
# Nur URL-/Shell-sichere Sonderzeichen -> keine Probleme in Connection-Strings.
ephemeral "random_password" "mysql_admin" {
  length           = 32
  special          = true
  override_special = "-_.~"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "azurerm_mysql_flexible_server" "main" {
  name                = var.mysql_server_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  version             = "8.0.21"
  sku_name            = var.mysql_sku

  administrator_login               = var.mysql_admin_login
  administrator_password_wo         = ephemeral.random_password.mysql_admin.result
  administrator_password_wo_version = var.mysql_password_version

  delegated_subnet_id   = azurerm_subnet.mysql.id
  private_dns_zone_id   = azurerm_private_dns_zone.mysql.id
  backup_retention_days = 7

  storage {
    size_gb           = 20
    auto_grow_enabled = true
  }

  lifecycle {
    ignore_changes = [zone]   # Azure wählt die Zone selbst
  }

  depends_on = [azurerm_private_dns_zone_virtual_network_link.mysql]
}

resource "azurerm_mysql_flexible_database" "django" {
  name                = var.mysql_database_name
  resource_group_name = azurerm_resource_group.main.name
  server_name         = azurerm_mysql_flexible_server.main.name
  charset             = "utf8mb4"
  collation           = "utf8mb4_unicode_ci"
}

# ======================= Secrets =======================

resource "azurerm_key_vault_secret" "django_secret_key" {
  name             = "django-secret-key"
  key_vault_id     = azurerm_key_vault.main.id
  value_wo         = var.django_secret_value
  value_wo_version = var.django_secret_version
  content_type     = "text/plain"

  depends_on = [time_sleep.wait_for_rbac]
}

resource "azurerm_key_vault_secret" "mysql_password" {
  name             = "mysql-admin-password"
  key_vault_id     = azurerm_key_vault.main.id
  value_wo         = ephemeral.random_password.mysql_admin.result   # identischer Wert wie in MySQL
  value_wo_version = var.mysql_password_version
  content_type     = "text/plain"

  depends_on = [time_sleep.wait_for_rbac]
}

resource "azurerm_key_vault_secret" "mysql_user" {
  name         = "mysql-admin-user"
  key_vault_id = azurerm_key_vault.main.id
  value        = var.mysql_admin_login

  depends_on = [time_sleep.wait_for_rbac]
}

resource "azurerm_key_vault_secret" "mysql_host" {
  name         = "mysql-host"
  key_vault_id = azurerm_key_vault.main.id
  value        = azurerm_mysql_flexible_server.main.fqdn

  depends_on = [time_sleep.wait_for_rbac]
}

resource "azurerm_key_vault_secret" "mysql_database" {
  name         = "mysql-database"
  key_vault_id = azurerm_key_vault.main.id
  value        = azurerm_mysql_flexible_database.django.name

  depends_on = [time_sleep.wait_for_rbac]
}

# ======================= Web App =======================

locals {
  kv_ref = {
    SECRET_KEY  = azurerm_key_vault_secret.django_secret_key.versionless_id
    DB_PASSWORD = azurerm_key_vault_secret.mysql_password.versionless_id
    DB_USER     = azurerm_key_vault_secret.mysql_user.versionless_id
    DB_HOST     = azurerm_key_vault_secret.mysql_host.versionless_id
    DB_NAME     = azurerm_key_vault_secret.mysql_database.versionless_id
  }
}

resource "azurerm_linux_web_app" "main" {
  name                      = var.web_app_name
  location                  = azurerm_resource_group.main.location
  resource_group_name       = azurerm_resource_group.main.name
  service_plan_id           = azurerm_service_plan.main.id
  https_only                = true
  virtual_network_subnet_id = azurerm_subnet.app.id

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  key_vault_reference_identity_id = azurerm_user_assigned_identity.app.id

  site_config {
    vnet_route_all_enabled = true   # Key-Vault-Referenzen + DB-Traffic über das VNet
    app_command_line       = "gunicorn --bind=0.0.0.0:8000 --timeout 600 myDjangoAzureProject.wsgi"

    application_stack {
      python_version = "3.14"
    }
  }

  app_settings = merge(
    {
      "DJANGO_SETTINGS_MODULE"         = "myDjangoAzureProject.settings"
      "SCM_DO_BUILD_DURING_DEPLOYMENT" = "true"
      "ENABLE_ORYX_BUILD"              = "true"
      "DB_PORT"                        = "3306"
    },
    { for k, id in local.kv_ref : k => "@Microsoft.KeyVault(SecretUri=${id})" }
  )

  depends_on = [
    time_sleep.wait_for_rbac,
    azurerm_private_endpoint.kv,
    azurerm_private_dns_zone_virtual_network_link.kv,
  ]
}

resource "azurerm_app_service_source_control" "github" {
  app_id   = azurerm_linux_web_app.main.id
  repo_url = "https://github.com/${var.github_owner}/${var.github_repo_name}"
  branch   = var.github_branch

  github_action_configuration {
    generate_workflow_file = true

    code_configuration {
      runtime_stack   = "python"
      runtime_version = "3.14"
    }
  }
}

# ======================= Outputs =======================

output "web_app_url"         { value = "https://${azurerm_linux_web_app.main.default_hostname}" }
output "resource_group"      { value = azurerm_resource_group.main.name }
output "key_vault_uri"       { value = azurerm_key_vault.main.vault_uri }
output "mysql_fqdn"          { value = azurerm_mysql_flexible_server.main.fqdn }
output "app_identity_client" { value = azurerm_user_assigned_identity.app.client_id }