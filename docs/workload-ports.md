# Workload ports

## Default policy

`aiaiaiai-org/infra` defines the default internal workload port by deployment class:

| Deployment | Default port |
| --- | ---: |
| Test | `1703` |
| Production | `1927` |

The rule is expressed as `*:1703` for test workloads and `*:1927` for production workloads. The port is part of the reviewed workload contract; edge upstreams must match the contract exactly.

## Contract requirements

Every workload contract declares `spec.deployment` as either `test` or `production` and uses the corresponding default port. The infra CI validator rejects a workload that uses another port.

Product repositories should therefore not choose an application port independently for a deployed workload. If a product genuinely requires a different port, the infra contract and its deployment-class policy must be changed deliberately in the same reviewed change.

## Current classes

- `market-bot-test` → `test` → `market-bot-development:1703`
- `market-api-production` → `production` → `market-api-production:1927`
- `market-bot-production` → `production` → `market-bot-production:1927`
- `nilxone-web` → `production` → `nilxone-web:1927`
- `nilxone-telegram` → `production` → `nilxone-telegram:1927`
- `nilxone-discord` → `production` → `nilxone-discord:1927`

## Why two ports?

The separation prevents a test workload from accidentally presenting itself on the production workload port and makes deployment class visible at the network boundary. It is an infra convention, not an application-level requirement.
