import * as path from 'path';
import Handlebars from 'handlebars';
import * as fs from 'fs';

// Register helpers (same as template-engine.ts)
Handlebars.registerHelper('pascalCase', (str: string) => {
  return str
    .split(/[-_\s]+/)
    .map((word) => word.charAt(0).toUpperCase() + word.slice(1).toLowerCase())
    .join('');
});

Handlebars.registerHelper('camelCase', (str: string) => {
  const pascal = str
    .split(/[-_\s]+/)
    .map((word) => word.charAt(0).toUpperCase() + word.slice(1).toLowerCase())
    .join('');
  return pascal.charAt(0).toLowerCase() + pascal.slice(1);
});

Handlebars.registerHelper('kebabCase', (str: string) => {
  return str
    .replace(/([a-z])([A-Z])/g, '$1-$2')
    .replace(/[\s_]+/g, '-')
    .toLowerCase();
});

Handlebars.registerHelper('snakeCase', (str: string) => {
  return str
    .replace(/([a-z])([A-Z])/g, '$1_$2')
    .replace(/[\s-]+/g, '_')
    .toLowerCase();
});

Handlebars.registerHelper('upperSnakeCase', (str: string) => {
  return str
    .replace(/([a-z])([A-Z])/g, '$1_$2')
    .replace(/[\s-]+/g, '_')
    .toUpperCase();
});

Handlebars.registerHelper('upperCase', (str: string) => str.toUpperCase());
Handlebars.registerHelper('lowerCase', (str: string) => str.toLowerCase());
Handlebars.registerHelper('eq', (a: unknown, b: unknown) => a === b);

const TEMPLATES_DIR = path.resolve(__dirname, '..', 'src', 'templates');

function loadAndRender(templateName: string, context: Record<string, unknown>): string {
  const templatePath = path.join(TEMPLATES_DIR, `${templateName}.hbs`);
  const source = fs.readFileSync(templatePath, 'utf-8');
  const template = Handlebars.compile(source);
  return template(context);
}

describe('create-service templates', () => {
  const context = {
    serviceName: 'claims',
    port: 3010,
  };

  it('should render main.ts with correct port and service name', () => {
    const result = loadAndRender('main', context);
    expect(result).toContain("process.env.PORT || 3010");
    expect(result).toContain('Claims service running on port');
    expect(result).toContain("app.setGlobalPrefix('api/v1')");
  });

  it('should render app.module.ts with ConfigModule', () => {
    const result = loadAndRender('app-module', context);
    expect(result).toContain('ConfigModule.forRoot');
    expect(result).toContain('AppModule');
  });

  it('should render database config with service name', () => {
    const result = loadAndRender('database-config', context);
    expect(result).toContain("database: process.env.DB_DATABASE || 'claims'");
  });

  it('should render Dockerfile with correct port', () => {
    const result = loadAndRender('dockerfile', context);
    expect(result).toContain('EXPOSE 3010');
    expect(result).toContain('ENV PORT=3010');
  });

  it('should render docker-compose with correct service name and port', () => {
    const result = loadAndRender('docker-compose', context);
    expect(result).toContain('claims:');
    expect(result).toContain("'3010:3010'");
    expect(result).toContain('POSTGRES_DB=claims');
  });

  it('should render .env.example with correct values', () => {
    const result = loadAndRender('env-example', context);
    expect(result).toContain('PORT=3010');
    expect(result).toContain('DB_DATABASE=claims');
  });

  it('should render CLAUDE.md with service name', () => {
    const result = loadAndRender('service-claude-md', context);
    expect(result).toContain('# Zorbit Service: claims');
    expect(result).toContain('claims service');
  });

  it('should render hash-id service with generate and validate methods', () => {
    const result = loadAndRender('hash-id-service', context);
    expect(result).toContain('HashIdService');
    expect(result).toContain('generate(prefix: string)');
    expect(result).toContain('validate(hashId: string');
  });

  it('should render event publisher service with service name', () => {
    const result = loadAndRender('event-publisher-service', context);
    expect(result).toContain('EventPublisherService');
    expect(result).toContain("source: 'claims'");
  });
});
