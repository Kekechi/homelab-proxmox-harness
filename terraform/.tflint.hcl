plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

rule "terraform_unused_declarations" {
  # Variables are pre-declared for module use. Suppress until module calls are active.
  enabled = false
}
