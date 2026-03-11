import Handlebars from 'handlebars';
import * as fs from 'fs-extra';
import * as path from 'path';

// Register custom Handlebars helpers

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

Handlebars.registerHelper('upperCase', (str: string) => {
  return str.toUpperCase();
});

Handlebars.registerHelper('lowerCase', (str: string) => {
  return str.toLowerCase();
});

Handlebars.registerHelper('eq', (a: unknown, b: unknown) => {
  return a === b;
});

/**
 * Get the path to the templates directory.
 */
export function getTemplatesDir(): string {
  return path.resolve(__dirname, '..', 'templates');
}

/**
 * Load and compile a Handlebars template from the templates directory.
 */
export function loadTemplate(templateName: string): HandlebarsTemplateDelegate {
  const templatesDir = getTemplatesDir();
  const templatePath = path.join(templatesDir, `${templateName}.hbs`);

  if (!fs.existsSync(templatePath)) {
    throw new Error(`Template not found: ${templatePath}`);
  }

  const templateSource = fs.readFileSync(templatePath, 'utf-8');
  return Handlebars.compile(templateSource);
}

/**
 * Render a template with the given context data.
 */
export function renderTemplate(
  templateName: string,
  context: Record<string, unknown>,
): string {
  const template = loadTemplate(templateName);
  return template(context);
}

/**
 * Render a raw template string with the given context data.
 */
export function renderString(
  templateSource: string,
  context: Record<string, unknown>,
): string {
  const template = Handlebars.compile(templateSource);
  return template(context);
}
