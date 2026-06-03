output "jumpbox_ip" {
  description = "SSH into this to reach frontend and backend VMs"
  value       = azurerm_public_ip.jumpbox.ip_address
}

output "frontend_private_ip" {
  value = "10.0.2.4"
}

output "backend_private_ip" {
  value = "10.0.2.5"
}

output "key_vault_url" {
  description = "Set this as KEY_VAULT_URL env var on backend VM"
  value       = azurerm_key_vault.main.vault_uri
}

output "postgres_host" {
  value = "${azurerm_postgresql_flexible_server.main.name}.postgres.database.azure.com"
}

output "ssh_jumpbox" {
  value = "ssh azureuser@${azurerm_public_ip.jumpbox.ip_address}"
}

output "ssh_frontend_via_jumpbox" {
  value = "ssh -J azureuser@${azurerm_public_ip.jumpbox.ip_address} azureuser@10.0.2.4"
}

output "ssh_backend_via_jumpbox" {
  value = "ssh -J azureuser@${azurerm_public_ip.jumpbox.ip_address} azureuser@10.0.2.5"
}
