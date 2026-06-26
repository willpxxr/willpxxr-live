data "ovh_me" "main" {}

data "ovh_order_cart" "main" {
  ovh_subsidiary = "IE"
}

data "ovh_order_cart_product_plan" "cloud" {
  cart_id        = data.ovh_order_cart.main.id
  price_capacity = "renew"
  product        = "cloud"
  plan_code      = "project.2018"
}

resource "ovh_cloud_project" "main" {
  ovh_subsidiary      = "IE"
  description         = "willpxxr-live"
  deletion_protection = true

  plan {
    duration     = data.ovh_order_cart_product_plan.cloud.selected_price.0.duration
    plan_code    = data.ovh_order_cart_product_plan.cloud.plan_code
    pricing_mode = data.ovh_order_cart_product_plan.cloud.selected_price.0.pricing_mode
  }
}
