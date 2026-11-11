# Bob, through the agent he named in may_act, in his own namespace only.
# kubectl first reads what the cluster serves: API discovery, version, OpenAPI.
path "k8s-actor/role/+/gateway/api" {
  capabilities = ["read"]
  condition    = "user.present && user.metadata.may_act_sub == agent.principal && user.principal == 'bob'"
}
path "k8s-actor/role/+/gateway/api/v1" {
  capabilities = ["read"]
  condition    = "user.present && user.metadata.may_act_sub == agent.principal && user.principal == 'bob'"
}
path "k8s-actor/role/+/gateway/apis" {
  capabilities = ["read"]
  condition    = "user.present && user.metadata.may_act_sub == agent.principal && user.principal == 'bob'"
}
path "k8s-actor/role/+/gateway/apis/+/+" {
  capabilities = ["read"]
  condition    = "user.present && user.metadata.may_act_sub == agent.principal && user.principal == 'bob'"
}
path "k8s-actor/role/+/gateway/version" {
  capabilities = ["read"]
  condition    = "user.present && user.metadata.may_act_sub == agent.principal && user.principal == 'bob'"
}
path "k8s-actor/role/+/gateway/openapi/*" {
  capabilities = ["read"]
  condition    = "user.present && user.metadata.may_act_sub == agent.principal && user.principal == 'bob'"
}
# The bob namespace object, and everything in it, core and every API group.
path "k8s-actor/role/+/gateway/api/v1/namespaces/bob" {
  capabilities = ["read"]
  condition    = "user.present && user.metadata.may_act_sub == agent.principal && user.principal == 'bob'"
}
path "k8s-actor/role/+/gateway/api/v1/namespaces/bob/*" {
  capabilities = ["read", "list", "create", "update", "patch", "delete"]
  condition    = "user.present && user.metadata.may_act_sub == agent.principal && user.principal == 'bob'"
}
path "k8s-actor/role/+/gateway/apis/+/+/namespaces/bob/*" {
  capabilities = ["read", "list", "create", "update", "patch", "delete"]
  condition    = "user.present && user.metadata.may_act_sub == agent.principal && user.principal == 'bob'"
}
# "Can I?" and "who am I?": the agent asking the API about its own permissions.
path "k8s-actor/role/+/gateway/apis/authorization.k8s.io/v1/selfsubjectaccessreviews" {
  capabilities = ["create"]
  condition    = "user.present && user.metadata.may_act_sub == agent.principal && user.principal == 'bob'"
}
path "k8s-actor/role/+/gateway/apis/authorization.k8s.io/v1/selfsubjectrulesreviews" {
  capabilities = ["create"]
  condition    = "user.present && user.metadata.may_act_sub == agent.principal && user.principal == 'bob'"
}
path "k8s-actor/role/+/gateway/apis/authentication.k8s.io/v1/selfsubjectreviews" {
  capabilities = ["create"]
  condition    = "user.present && user.metadata.may_act_sub == agent.principal && user.principal == 'bob'"
}
