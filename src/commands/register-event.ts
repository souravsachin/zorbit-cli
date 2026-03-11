import { Command } from 'commander';
import * as path from 'path';
import chalk from 'chalk';
import { renderTemplate } from '../utils/template-engine';
import { writeFile, exists, readJson, writeJson } from '../utils/file-utils';

const EVENT_NAME_PATTERN = /^[a-z][a-z0-9-]*\.[a-z][a-z0-9-]*\.[a-z][a-z0-9-]*$/;

export function registerEventCommand(program: Command): void {
  program
    .command('register-event <eventName>')
    .description(
      'Register an event in the platform registry (format: domain.entity.action)',
    )
    .option(
      '--core-path <path>',
      'Path to zorbit-core repository',
    )
    .action(async (eventName: string, options: { corePath?: string }) => {
      try {
        // Validate event name format
        if (!EVENT_NAME_PATTERN.test(eventName)) {
          console.error(
            chalk.red(
              `Invalid event name: "${eventName}". Must follow format: domain.entity.action (lowercase, alphanumeric with hyphens)`,
            ),
          );
          process.exit(1);
        }

        const parts = eventName.split('.');
        const domain = parts[0];
        const entity = parts[1];
        const action = parts[2];

        console.log(chalk.blue(`\nRegistering event: ${eventName}\n`));
        console.log(chalk.gray(`  Domain: ${domain}`));
        console.log(chalk.gray(`  Entity: ${entity}`));
        console.log(chalk.gray(`  Action: ${action}`));

        // Try to register in zorbit-core event registry
        const corePath = options.corePath || findCorePath();
        if (corePath) {
          const registryPath = path.join(
            corePath,
            'event-registry',
            'registry.json',
          );

          if (await exists(registryPath)) {
            const registry = await readJson<{
              events: Array<{
                name: string;
                domain: string;
                entity: string;
                action: string;
              }>;
            }>(registryPath);

            const alreadyExists = registry.events.some(
              (e) => e.name === eventName,
            );

            if (alreadyExists) {
              console.log(
                chalk.yellow(`  Event "${eventName}" already registered in core registry.`),
              );
            } else {
              registry.events.push({
                name: eventName,
                domain,
                entity,
                action,
              });
              await writeJson(registryPath, registry);
              console.log(
                chalk.green(`  Added to core event registry: ${registryPath}`),
              );
            }
          } else {
            console.log(
              chalk.yellow(
                '  Core event registry not found. Skipping registry update.',
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

        // Generate event constant in current service (if in a service dir)
        const cwd = process.cwd();
        const eventsDir = path.join(cwd, 'src', 'events');

        if (await exists(eventsDir)) {
          const eventConstant = eventName.replace(/\./g, '_');
          const context = {
            eventName,
            eventConstant,
            domain,
            entity,
            action,
          };

          const content = renderTemplate('event-constant', context);
          const fileName = `${domain}-${entity}-${action}.event.ts`;
          await writeFile(path.join(eventsDir, fileName), content);
        }

        console.log(chalk.green(`\nEvent "${eventName}" registered.`));
      } catch (error) {
        console.error(chalk.red('Error registering event:'), error);
        process.exit(1);
      }
    });
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
