# Zorbit CLI

CLI tool for scaffolding and managing Zorbit platform services.

## Installation

```bash
npm install -g @zorbit-platform/cli
```

Or link locally for development:

```bash
npm install
npm run build
npm link
```

## Usage

### Create a new service

```bash
zorbit create-service claims
```

Scaffolds a new NestJS service with full Zorbit platform conventions including JWT auth, namespace isolation, hash IDs, and event publishing.

### Create a module within a service

```bash
zorbit create-module customer
```

Creates controller, service, entity, DTO, module, and test files following Zorbit patterns.

### Register an event

```bash
zorbit register-event policy.claim.submitted
```

Validates the event name format and registers it in the platform event registry.

### Register a privilege

```bash
zorbit register-privilege CLAIMS_READ
```

Registers a privilege code in the platform privilege registry with an auto-generated hash ID.

### Generate a CRUD API

```bash
zorbit generate-api customer
```

Generates a full CRUD API with controller, service, entity, DTOs, module, and tests following Zorbit REST grammar.

## Development

```bash
npm run build    # Compile TypeScript
npm run dev      # Run via ts-node
npm test         # Run tests
```
