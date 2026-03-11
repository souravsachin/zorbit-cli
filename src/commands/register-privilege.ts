import { Command } from 'commander';
import * as path from 'path';
import chalk from 'chalk';
import {
  exists,
  readJson,
  writeJson,
  generateHashId,
} from '../utils/file-utils';

const PRIVILEGE_CODE_PATTERN = /^[A-Z][A-Z0-9_]*$/;

export function registerPrivilegeCommand(program: Command): void {
  program
    .command('register-privilege <code>')
    .description('Register a privilege in the platform registry')
    .option('--description <desc>', 'Description of the privilege')
    .option('--core-path <path>', 'Path to zorbit-core repository')
    .action(
      async (
        code: string,
        options: { description?: string; corePath?: string },
      ) => {
        try {
          // Validate privilege code format
          if (!PRIVILEGE_CODE_PATTERN.test(code)) {
            console.error(
              chalk.red(
                `Invalid privilege code: "${code}". Must be uppercase alphanumeric with underscores (e.g., CLAIMS_READ).`,
              ),
            );
            process.exit(1);
          }

          const hashId = generateHashId('PRV');
          const description = options.description || `Privilege: ${code}`;

          console.log(chalk.blue(`\nRegistering privilege: ${code}\n`));
          console.log(chalk.gray(`  Hash ID: ${hashId}`));
          console.log(chalk.gray(`  Description: ${description}`));

          // Try to register in zorbit-core privilege registry
          const corePath = options.corePath || findCorePath();
          if (corePath) {
            const registryPath = path.join(
              corePath,
              'privilege-registry',
              'registry.json',
            );

            if (await exists(registryPath)) {
              const registry = await readJson<{
                privileges: Array<{
                  code: string;
                  hashId: string;
                  description: string;
                }>;
              }>(registryPath);

              const alreadyExists = registry.privileges.some(
                (p) => p.code === code,
              );

              if (alreadyExists) {
                console.log(
                  chalk.yellow(
                    `  Privilege "${code}" already registered in core registry.`,
                  ),
                );
              } else {
                registry.privileges.push({
                  code,
                  hashId,
                  description,
                });
                await writeJson(registryPath, registry);
                console.log(
                  chalk.green(
                    `  Added to core privilege registry: ${registryPath}`,
                  ),
                );
              }
            } else {
              console.log(
                chalk.yellow(
                  '  Core privilege registry not found. Skipping registry update.',
                ),
              );
            }
          } else {
            console.log(
              chalk.yellow(
                '  zorbit-core not found. Use --core-path to specify location.',
              ),
            );
          }

          console.log(chalk.green(`\nPrivilege "${code}" registered with ID: ${hashId}`));
        } catch (error) {
          console.error(chalk.red('Error registering privilege:'), error);
          process.exit(1);
        }
      },
    );
}

/**
 * Try to find zorbit-core relative to the current directory.
 */
function findCorePath(): string | null {
  const candidates = [
    path.resolve(process.cwd(), '..', 'zorbit-core'),
    path.resolve(process.cwd(), '..', '..', 'zorbit-core'),
  ];

  for (const candidate of candidates) {
    try {
      const fs = require('fs');
      if (fs.existsSync(candidate)) {
        return candidate;
      }
    } catch {
      // ignore
    }
  }

  return null;
}
