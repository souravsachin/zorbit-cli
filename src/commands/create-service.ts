import { Command } from 'commander';
import inquirer from 'inquirer';
import * as path from 'path';
import chalk from 'chalk';
import { renderTemplate } from '../utils/template-engine';
import { writeFile, ensureDirectory } from '../utils/file-utils';

interface CreateServiceAnswers {
  port: number;
}

export function createServiceCommand(program: Command): void {
  program
    .command('create-service <name>')
    .description('Scaffold a new Zorbit NestJS service')
    .option('-p, --port <port>', 'Service port number')
    .option('-d, --dir <directory>', 'Target directory', '.')
    .action(async (name: string, options: { port?: string; dir: string }) => {
      try {
        let port = options.port ? parseInt(options.port, 10) : 0;

        if (!port) {
          const answers = await inquirer.prompt<CreateServiceAnswers>([
            {
              type: 'number',
              name: 'port',
              message: 'Port number for the service:',
              default: 3000,
              validate: (val: number) =>
                val > 0 && val < 65536 ? true : 'Enter a valid port number',
            },
          ]);
          port = answers.port;
        }

        const serviceName = name.toLowerCase().replace(/\s+/g, '-');
        const targetDir = path.resolve(options.dir, `zorbit-${serviceName}`);

        console.log(
          chalk.blue(`\nCreating Zorbit service: ${serviceName}\n`),
        );

        const context = { serviceName, port };

        // Create directory structure
        const dirs = [
          'src/api',
          'src/controllers',
          'src/services',
          'src/models/entities',
          'src/models/dto',
          'src/events',
          'src/middleware',
          'src/config',
          'src/modules',
          'tests',
        ];

        for (const dir of dirs) {
          await ensureDirectory(path.join(targetDir, dir));
        }

        // Generate files from templates
        const files: Array<{ template: string; output: string }> = [
          { template: 'main', output: 'src/main.ts' },
          { template: 'app-module', output: 'src/app.module.ts' },
          { template: 'database-config', output: 'src/config/database.config.ts' },
          { template: 'app-config', output: 'src/config/app.config.ts' },
          { template: 'jwt-auth-guard', output: 'src/middleware/jwt-auth.guard.ts' },
          { template: 'namespace-guard', output: 'src/middleware/namespace.guard.ts' },
          { template: 'jwt-strategy', output: 'src/middleware/jwt.strategy.ts' },
          { template: 'hash-id-service', output: 'src/services/hash-id.service.ts' },
          {
            template: 'event-publisher-service',
            output: 'src/events/event-publisher.service.ts',
          },
          { template: 'dockerfile', output: 'Dockerfile' },
          { template: 'docker-compose', output: 'docker-compose.yml' },
          { template: 'env-example', output: '.env.example' },
          { template: 'gitignore', output: '.gitignore' },
          { template: 'service-claude-md', output: 'CLAUDE.md' },
          { template: 'service-readme', output: 'README.md' },
          { template: 'service-package-json', output: 'package.json' },
          { template: 'service-tsconfig', output: 'tsconfig.json' },
          { template: 'nest-cli-json', output: 'nest-cli.json' },
        ];

        for (const file of files) {
          const content = renderTemplate(file.template, context);
          await writeFile(path.join(targetDir, file.output), content);
        }

        console.log(chalk.green(`\nService ${serviceName} created at ${targetDir}`));
        console.log(chalk.gray('\nNext steps:'));
        console.log(chalk.gray(`  cd ${targetDir}`));
        console.log(chalk.gray('  npm install'));
        console.log(chalk.gray('  cp .env.example .env'));
        console.log(chalk.gray('  npm run start:dev'));
      } catch (error) {
        console.error(chalk.red('Error creating service:'), error);
        process.exit(1);
      }
    });
}
