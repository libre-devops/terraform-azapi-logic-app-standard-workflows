variable "deployed_branch" {
  description = "Branch this was deployed from, for the tag module."
  type        = string
  default     = "local"
}

variable "deployed_repo" {
  description = "Repository this was deployed from, for the tag module."
  type        = string
  default     = "terraform-azapi-logic-app-standard-workflows"
}

variable "loc" {
  description = "Short region code used in resource names."
  type        = string
  default     = "uks"
}

variable "short" {
  description = "Short organisation prefix used in resource names."
  type        = string
  default     = "ldo"
}
