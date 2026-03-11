import { Command } from 'commander';
import * as path from 'path';
import chalk from 'chalk';
import { renderTemplate } from '../utils/template-engine';
import { writeFile, exists } from '../utils/file-utils';

export function createModuleCommand(program: Command): void {
  program
    .command('create-module <name>')
    .description('Create a new module within an existing Zorbit service')
    .option(
      '-s, --scope <scope>',
      'Namespace scope (G/O/D/U)',
      'O',
    )
    .option(
      '--prefix <prefix>',
      'Hash ID prefix for entities',
    )
    .action(async (name: string, options: { scope: string; prefix?: string }) => {
      try {
        const cwd = process.cwd();
        const srcDir = path.join(cwd, 'src');

        if (!(await exists(srcDir))) {
          console.error(
            chalk.red(
              'Error: src/ directory not found. Run this command from within a Zorbit service directory.',
            ),
          );
          process.exit(1);
        }

        const moduleName = name.toLowerCase().replace(/\s+/g, '-');
        const namespaceScope = options.scope.toUpperCase();
        const hashPrefix = options.prefix || moduleName.substring(0, 3).toUpperCase();

        let namespaceRoute = '';
        switch (namespaceScope) {
          case 'O':
            namespaceRoute = 'O/:orgId/';
            break;
          case 'D':
            namespaceRoute = 'O/:orgId/D/:deptId/';
            break;
          case 'U':
            namespaceRoute = 'U/:userId/';
            break;
          case 'G':
          default:
            namespaceRoute = '';
            break;
        }

        const context = {
          name: moduleName,
          namespaceScope,
          namespaceRoute,
          hashPrefix,
        };

        console.log(
          chalk.blue(
            `\nCreating module: ${moduleName} (namespace: ${namespaceScope})\n`,
          ),
        );

        const files: Array<{ template: string; output: string }> = [
          {
            template: 'controller',
            output: `src/controllers/${moduleName}.controller.ts`,
          },
          {
            template: 'service',
            output: `src/services/${moduleName}.service.ts`,
          },
          {
            template: 'entity',
            output: `src/models/entities/${moduleName}.entity.ts`,
          },
          {
            template: 'dto',
            output: `src/models/dto/create-${moduleName}.dto.ts`,
          },
          {
            template: 'module',
            output: `src/modules/${moduleName}.module.ts`,
          },
          {
            template: 'test',
            output: `tests/${moduleName}.service.spec.ts`,
          },
        ];

        for (const file of files) {
          const content = renderTemplate(file.template, context);
          await writeFile(path.join(cwd, file.output), content);
        }

        console.log(chalk.green(`\nModule ${moduleName} created.`));
        console.log(chalk.gray('\nRemember to import the module in app.module.ts:'));
        console.log(
          chalk.gray(
            `  import { ${toPascalCase(moduleName)}Module } from './modules/${moduleName}.module';`,
          ),
        );
      } catch (error) {
        console.error(chalk.red('Error creating module:'), error);
        process.exit(1);
      }
    });
}

function toPascalCase(str: string): string {
  return str
    .split(/[-_\s]+/)
    .map((word) => word.charAt(0).toUpperCase() + word.slice(1).toLowerCase())
    .join('');
}
