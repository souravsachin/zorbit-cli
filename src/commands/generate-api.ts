import { Command } from 'commander';
import inquirer from 'inquirer';
import * as path from 'path';
import chalk from 'chalk';
import { renderTemplate } from '../utils/template-engine';
import { writeFile, exists } from '../utils/file-utils';

interface GenerateApiAnswers {
  namespaceScope: string;
  hashPrefix: string;
}

export function generateApiCommand(program: Command): void {
  program
    .command('generate-api <resource>')
    .description('Generate a full CRUD API for a resource')
    .option('-s, --scope <scope>', 'Namespace scope (G/O/D/U)')
    .option('--prefix <prefix>', 'Hash ID prefix for entities')
    .action(async (resource: string, options: { scope?: string; prefix?: string }) => {
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

        let namespaceScope = options.scope?.toUpperCase() || '';
        let hashPrefix = options.prefix || '';

        if (!namespaceScope || !hashPrefix) {
          const answers = await inquirer.prompt<GenerateApiAnswers>([
            ...(namespaceScope
              ? []
              : [
                  {
                    type: 'list' as const,
                    name: 'namespaceScope' as const,
                    message: 'Namespace scope:',
                    choices: [
                      { name: 'G - Global', value: 'G' },
                      { name: 'O - Organization', value: 'O' },
                      { name: 'D - Department', value: 'D' },
                      { name: 'U - User', value: 'U' },
                    ],
                    default: 'O',
                  },
                ]),
            ...(hashPrefix
              ? []
              : [
                  {
                    type: 'input' as const,
                    name: 'hashPrefix' as const,
                    message: 'Hash ID prefix (e.g., CUS for customer):',
                    default: resource.substring(0, 3).toUpperCase(),
                    validate: (val: string) =>
                      /^[A-Z]{2,5}$/.test(val)
                        ? true
                        : 'Prefix must be 2-5 uppercase letters',
                  },
                ]),
          ]);

          if (!namespaceScope) namespaceScope = answers.namespaceScope;
          if (!hashPrefix) hashPrefix = answers.hashPrefix;
        }

        const resourceName = resource.toLowerCase().replace(/\s+/g, '-');

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
          name: resourceName,
          namespaceScope,
          namespaceRoute,
          hashPrefix,
        };

        console.log(
          chalk.blue(
            `\nGenerating CRUD API for: ${resourceName} (scope: ${namespaceScope}, prefix: ${hashPrefix})\n`,
          ),
        );

        const files: Array<{ template: string; output: string }> = [
          {
            template: 'controller',
            output: `src/controllers/${resourceName}.controller.ts`,
          },
          {
            template: 'service',
            output: `src/services/${resourceName}.service.ts`,
          },
          {
            template: 'entity',
            output: `src/models/entities/${resourceName}.entity.ts`,
          },
          {
            template: 'dto',
            output: `src/models/dto/create-${resourceName}.dto.ts`,
          },
          {
            template: 'module',
            output: `src/modules/${resourceName}.module.ts`,
          },
          {
            template: 'test',
            output: `tests/${resourceName}.service.spec.ts`,
          },
        ];

        for (const file of files) {
          const content = renderTemplate(file.template, context);
          await writeFile(path.join(cwd, file.output), content);
        }

        console.log(chalk.green(`\nCRUD API for ${resourceName} generated.`));
        console.log(chalk.gray('\nGenerated endpoints:'));
        console.log(
          chalk.gray(
            `  POST   /api/v1/${namespaceRoute}${resourceName}s`,
          ),
        );
        console.log(
          chalk.gray(
            `  GET    /api/v1/${namespaceRoute}${resourceName}s`,
          ),
        );
        console.log(
          chalk.gray(
            `  GET    /api/v1/${namespaceRoute}${resourceName}s/:hashId`,
          ),
        );
        console.log(
          chalk.gray(
            `  PUT    /api/v1/${namespaceRoute}${resourceName}s/:hashId`,
          ),
        );
        console.log(
          chalk.gray(
            `  DELETE /api/v1/${namespaceRoute}${resourceName}s/:hashId`,
          ),
        );
        console.log(
          chalk.gray(
            `\nRemember to import the module in app.module.ts.`,
          ),
        );
      } catch (error) {
        console.error(chalk.red('Error generating API:'), error);
        process.exit(1);
      }
    });
}
