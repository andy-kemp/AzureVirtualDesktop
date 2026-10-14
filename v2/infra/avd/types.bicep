// Mirrors the hostPool and scaling sections of contracts/avd-config.schema.json so the CLI can pass them through unchanged.
// The JSON Schema is the authoritative contract; these types add compile-time checks for the Bicep side.

@export()
type loadBalancing = 'BreadthFirst' | 'DepthFirst'

@export()
type hostPoolConfiguration = {
  type: 'Pooled' | 'Personal'
  @minValue(1)
  @maxValue(999)
  maxSessionLimit: int?
  loadBalancer: loadBalancing?
  assignmentType: ('Automatic' | 'Direct')?
}

@export()
type scalingConfiguration = {
  enabled: bool
  @description('Windows time zone ID, for example GMT Standard Time.')
  timeZone: string
  exclusionTag: string?
  @description('Pooled or personal schedule objects matching hostPool.type; shape is enforced by the JSON Schema contract.')
  @minLength(1)
  @maxLength(7)
  schedules: object[]
}
