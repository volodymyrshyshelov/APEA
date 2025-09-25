provider "azurerm" {
  features {
    storage {
      data_plane_available = false
    }
  }
}