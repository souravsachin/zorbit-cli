import * as fs from 'fs-extra';
import * as path from 'path';
import chalk from 'chalk';
import crypto from 'crypto';

/**
 * Ensure a directory exists, creating it if necessary.
 */
export async function ensureDirectory(dirPath: string): Promise<void> {
  await fs.ensureDir(dirPath);
}

/**
 * Write a file, creating parent directories as needed.
 * Logs the action to stdout.
 */
export async function writeFile(
  filePath: string,
  content: string,
): Promise<void> {
  await fs.ensureDir(path.dirname(filePath));
  await fs.writeFile(filePath, content, 'utf-8');
  console.log(chalk.green('  CREATE') + ' ' + filePath);
}

/**
 * Check if a file or directory exists.
 */
export async function exists(targetPath: string): Promise<boolean> {
  return fs.pathExists(targetPath);
}

/**
 * Read a JSON file and parse it.
 */
export async function readJson<T = unknown>(filePath: string): Promise<T> {
  return fs.readJson(filePath);
}

/**
 * Write a JSON file with pretty formatting.
 */
export async function writeJson(
  filePath: string,
  data: unknown,
): Promise<void> {
  await fs.ensureDir(path.dirname(filePath));
  await fs.writeJson(filePath, data, { spaces: 2 });
  console.log(chalk.green('  CREATE') + ' ' + filePath);
}

/**
 * Generate a short hash ID with a given prefix.
 * Pattern: <PREFIX>-<4-char hex>
 */
export function generateHashId(prefix: string): string {
  const hash = crypto.randomBytes(2).toString('hex').toUpperCase();
  return `${prefix}-${hash}`;
}

/**
 * Convert a string to PascalCase.
 */
export function toPascalCase(str: string): string {
  return str
    .split(/[-_\s]+/)
    .map((word) => word.charAt(0).toUpperCase() + word.slice(1).toLowerCase())
    .join('');
}

/**
 * Convert a string to camelCase.
 */
export function toCamelCase(str: string): string {
  const pascal = toPascalCase(str);
  return pascal.charAt(0).toLowerCase() + pascal.slice(1);
}

/**
 * Convert a string to kebab-case.
 */
export function toKebabCase(str: string): string {
  return str
    .replace(/([a-z])([A-Z])/g, '$1-$2')
    .replace(/[\s_]+/g, '-')
    .toLowerCase();
}

/**
 * Convert a string to UPPER_SNAKE_CASE.
 */
export function toUpperSnakeCase(str: string): string {
  return str
    .replace(/([a-z])([A-Z])/g, '$1_$2')
    .replace(/[\s-]+/g, '_')
    .toUpperCase();
}
