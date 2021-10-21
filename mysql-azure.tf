terraform {
  required_version = ">= 0.13"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 2.26"
    }
  }
}

provider "azurerm" {
  skip_provider_registration = true
  features {}
}

resource "azurerm_resource_group" "mysql_group" {
    name     = "mysql_group"
    location = "eastus"

    tags     = {
        "Environment" = "aula teste"
    }
}

resource "azurerm_virtual_network" "mysql_virtualnet" {
    name                = "mysql_virtualnet"
    address_space       = ["10.0.0.0/16"]
    location            = "eastus"
    resource_group_name = azurerm_resource_group.mysql_group.name

    depends_on = [ azurerm_resource_group.mysql_group ]
}

resource "azurerm_subnet" "mysql_subnet" {
    name                 = "mysql_subnet"
    resource_group_name  = azurerm_resource_group.mysql_group.name
    virtual_network_name = azurerm_virtual_network.mysql_virtualnet.name
    address_prefixes       = ["10.0.1.0/24"]
}

resource "azurerm_public_ip" "mysql_publicip" {
    name                         = "mysql_publicip"
    location                     = "eastus"
    resource_group_name          = azurerm_resource_group.mysql_group.name
    allocation_method            = "Static"
}

resource "azurerm_network_security_group" "mysql_netsecgroup" {
    name                = "mysql_netsecgroup"
    location            = "eastus"
    resource_group_name = azurerm_resource_group.mysql_group.name

    security_rule {
        name                       = "mysql"
        priority                   = 1001
        direction                  = "Inbound"
        access                     = "Allow"
        protocol                   = "Tcp"
        source_port_range          = "*"
        destination_port_range     = "3306"
        source_address_prefix      = "*"
        destination_address_prefix = "*"
    }

    security_rule {
        name                       = "SSH"
        priority                   = 1002
        direction                  = "Inbound"
        access                     = "Allow"
        protocol                   = "Tcp"
        source_port_range          = "*"
        destination_port_range     = "22"
        source_address_prefix      = "*"
        destination_address_prefix = "*"
    }
}

resource "azurerm_network_interface" "mysql_networkinterface" {
    name                      = "mysql_networkinterface"
    location                  = "eastus"
    resource_group_name       = azurerm_resource_group.mysql_group.name

    ip_configuration {
        name                          = "myNicConfiguration"
        subnet_id                     = azurerm_subnet.mysql_subnet.id
        private_ip_address_allocation = "Dynamic"
        public_ip_address_id          = azurerm_public_ip.mysql_publicip.id
    }
}

resource "azurerm_network_interface_security_group_association" "netintersecgroupassoc01" {
    network_interface_id      = azurerm_network_interface.mysql_networkinterface.id
    network_security_group_id = azurerm_network_security_group.mysql_netsecgroup.id
}

data "azurerm_public_ip" "ip_aula_data_db" {
  name                = azurerm_public_ip.mysql_publicip.name
  resource_group_name = azurerm_resource_group.mysql_group.name
}

resource "azurerm_storage_account" "storage_account_mysql" {
    name                        = "storageaccountmysql"
    resource_group_name         = azurerm_resource_group.mysql_group.name
    location                    = "eastus"
    account_tier                = "Standard"
    account_replication_type    = "LRS"
}


resource "azurerm_mysql_server" "mysqlservertest007" {
    name                = "mysqlservertest007"
    location            = "eastus"
    resource_group_name = azurerm_resource_group.mysql_group.name

    administrator_login          = "mysql_adm"
    administrator_login_password = "@DzZsRYsr0ku"

    sku_name   = "B_Gen5_2"
    storage_mb = 5120
    version    = "5.7"

    auto_grow_enabled                 = true
    backup_retention_days             = 7
    geo_redundant_backup_enabled      = false
    infrastructure_encryption_enabled = false
    public_network_access_enabled     = true
    ssl_enforcement_enabled           = true
    ssl_minimal_tls_version_enforced  = "TLS1_2"
}

resource "azurerm_mysql_database" "mbadbmysql" {
    name                = "mbadbmysql"
    resource_group_name = azurerm_resource_group.mysql_group.name
    server_name         = azurerm_mysql_server.mysqlservertest007.name
    charset             = "utf8"
    collation           = "utf8_unicode_ci"
}

resource "azurerm_linux_virtual_machine" "vm_mysql" {
    name                  = "vm_mysql"
    location              = "eastus"
    resource_group_name   = azurerm_resource_group.mysql_group.name
    network_interface_ids = [azurerm_network_interface.mysql_networkinterface.id]
    size                  = "Standard_DS1_v2"

    os_disk {
        name              = "myOsDiskMySQL"
        caching           = "ReadWrite"
        storage_account_type = "Premium_LRS"
    }

    source_image_reference {
        publisher = "Canonical"
        offer     = "UbuntuServer"
        sku       = "18.04-LTS"
        version   = "latest"
    }

    computer_name  = "mysqlvm"
    admin_username = var.user
    admin_password = var.password
    disable_password_authentication = false

    boot_diagnostics {
        storage_account_uri = azurerm_storage_account.storage_account_mysql.primary_blob_endpoint
    }

    depends_on = [ azurerm_resource_group.mysql_group ]
}

output "public_ip_address_mysql" {
    value = azurerm_public_ip.mysql_publicip.ip_address
}

resource "azurerm_mysql_firewall_rule" "mysql-fw-rule" {
    name                = "mysql-fw-rule"
    resource_group_name = azurerm_resource_group.mysql_group.name
    server_name         = azurerm_mysql_server.mysqlservertest007.name
    start_ip_address    = "0.0.0.0"
    end_ip_address      = "0.0.0.0"
}

resource "time_sleep" "wait_30_seconds_db" {
  depends_on = [azurerm_linux_virtual_machine.vm_mysql]
  create_duration = "30s"
}

resource "null_resource" "upload_db" {
    provisioner "file" {
        connection {
            type = "ssh"
            user = var.user
            password = var.password
            host = data.azurerm_public_ip.ip_aula_data_db.ip_address
        }
        source = "mysql"
        destination = "/home/azureuser"
    }

    depends_on = [ time_sleep.wait_30_seconds_db ]
}

resource "null_resource" "deploy_db" {
    triggers = {
        order = null_resource.upload_db.id
    }
    provisioner "remote-exec" {
        connection {
            type = "ssh"
            user = var.user
            password = var.password
            host = data.azurerm_public_ip.ip_aula_data_db.ip_address
        }
        inline = [
            "sudo apt-get update",
            "sudo apt-get install -y mysql-server-5.7",
            "sudo mysql < /home/azureuser/mysql/script/user.sql",
            "sudo cp -f /home/azureuser/mysql/mysqld.cnf /etc/mysql/mysql.conf.d/mysqld.cnf",
            "sudo service mysql restart",
            "sleep 20",
        ]
    }
}