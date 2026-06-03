terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = true
    }
  }
}

data "azurerm_client_config" "current" {}

# --- Resource Group ---
resource "azurerm_resource_group" "main" {
  name     = var.resource_group_name
  location = var.location
}

# --- Networking ---
resource "azurerm_virtual_network" "main" {
  name                = "3tier-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_subnet" "public" {
  name                 = "public-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet" "private" {
  name                 = "private-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.2.0/24"]
}

resource "azurerm_subnet" "db" {
  name                 = "db-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.3.0/24"]
  delegation {
    name = "postgres-delegation"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "appgw" {
  name                 = "appgw-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.4.0/26"]
}

# --- NSG: Private subnet (frontend + backend VMs) ---
resource "azurerm_network_security_group" "private" {
  name                = "nsg-private"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  security_rule {
    name                       = "Allow-AppGW-Frontend"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "5000"
    source_address_prefix      = "10.0.4.0/26"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-Frontend-Backend"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "5001"
    source_address_prefix      = "10.0.2.0/24"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-JumpBox-SSH"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "10.0.1.0/24"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "private" {
  subnet_id                 = azurerm_subnet.private.id
  network_security_group_id = azurerm_network_security_group.private.id
}

# --- Jump Box VM (public subnet) ---
resource "azurerm_public_ip" "jumpbox" {
  name                = "jumpbox-pip"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_interface" "jumpbox" {
  name                = "jumpbox-nic"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.public.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.jumpbox.id
  }
}

resource "azurerm_linux_virtual_machine" "jumpbox" {
  name                = "vm-jumpbox"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  size                = "Standard_B1s"
  admin_username      = "azureuser"
  network_interface_ids = [azurerm_network_interface.jumpbox.id]
  admin_ssh_key {
    username   = "azureuser"
    public_key = file(var.ssh_public_key_path)
  }
  os_disk { caching = "ReadWrite"; storage_account_type = "Standard_LRS" }
  source_image_reference {
    publisher = "Canonical"; offer = "ubuntu-24_04-lts"
    sku = "server-arm64"; version = "latest"
  }
}

# --- Frontend VM ---
resource "azurerm_network_interface" "frontend" {
  name                = "frontend-nic"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.private.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.2.4"
  }
}

resource "azurerm_linux_virtual_machine" "frontend" {
  name                = "vm-frontend"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  size                = "Standard_B2pts_v2"
  admin_username      = "azureuser"
  network_interface_ids = [azurerm_network_interface.frontend.id]
  admin_ssh_key {
    username   = "azureuser"
    public_key = file(var.ssh_public_key_path)
  }
  os_disk { caching = "ReadWrite"; storage_account_type = "Standard_LRS" }
  source_image_reference {
    publisher = "Canonical"; offer = "ubuntu-24_04-lts"
    sku = "server-arm64"; version = "latest"
  }
  identity { type = "SystemAssigned" }
}

# --- Backend VM ---
resource "azurerm_network_interface" "backend" {
  name                = "backend-nic"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.private.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.2.5"
  }
}

resource "azurerm_linux_virtual_machine" "backend" {
  name                = "vm-backend"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  size                = "Standard_B2pts_v2"
  admin_username      = "azureuser"
  network_interface_ids = [azurerm_network_interface.backend.id]
  admin_ssh_key {
    username   = "azureuser"
    public_key = file(var.ssh_public_key_path)
  }
  os_disk { caching = "ReadWrite"; storage_account_type = "Standard_LRS" }
  source_image_reference {
    publisher = "Canonical"; offer = "ubuntu-24_04-lts"
    sku = "server-arm64"; version = "latest"
  }
  identity { type = "SystemAssigned" }
}

# --- Key Vault ---
resource "azurerm_key_vault" "main" {
  name                = var.key_vault_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"
  enable_rbac_authorization = true
}

# Give Terraform operator access to set secrets
resource "azurerm_role_assignment" "kv_operator" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Give VMs access to read secrets
resource "azurerm_role_assignment" "frontend_kv" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_virtual_machine.frontend.identity[0].principal_id
}

resource "azurerm_role_assignment" "backend_kv" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_virtual_machine.backend.identity[0].principal_id
}

# --- Key Vault Secrets ---
resource "azurerm_key_vault_secret" "db_host" {
  name         = "db-host"
  value        = "${azurerm_postgresql_flexible_server.main.name}.postgres.database.azure.com"
  key_vault_id = azurerm_key_vault.main.id
  depends_on   = [azurerm_role_assignment.kv_operator]
}

resource "azurerm_key_vault_secret" "db_user" {
  name         = "db-user"
  value        = var.db_admin_user
  key_vault_id = azurerm_key_vault.main.id
  depends_on   = [azurerm_role_assignment.kv_operator]
}

resource "azurerm_key_vault_secret" "db_password" {
  name         = "db-password"
  value        = var.db_admin_password
  key_vault_id = azurerm_key_vault.main.id
  depends_on   = [azurerm_role_assignment.kv_operator]
}

# --- PostgreSQL Private DNS Zone ---
resource "azurerm_private_dns_zone" "postgres" {
  name                = "${var.postgres_server_name}.private.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                  = "postgres-dns-link"
  private_dns_zone_name = azurerm_private_dns_zone.postgres.name
  virtual_network_id    = azurerm_virtual_network.main.id
  resource_group_name   = azurerm_resource_group.main.name
}

# --- PostgreSQL Flexible Server (VNet integrated, no public IP) ---
resource "azurerm_postgresql_flexible_server" "main" {
  name                   = var.postgres_server_name
  resource_group_name    = azurerm_resource_group.main.name
  location               = azurerm_resource_group.main.location
  version                = "16"
  delegated_subnet_id    = azurerm_subnet.db.id
  private_dns_zone_id    = azurerm_private_dns_zone.postgres.id
  administrator_login    = var.db_admin_user
  administrator_password = var.db_admin_password
  zone                   = "1"
  storage_mb             = 32768
  sku_name               = "B_Standard_B1ms"
  depends_on             = [azurerm_private_dns_zone_virtual_network_link.postgres]
}
