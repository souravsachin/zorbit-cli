#!/usr/bin/env node

import { Command } from 'commander';
import { createServiceCommand } from './commands/create-service';
import { createModuleCommand } from './commands/create-module';
import { registerEventCommand } from './commands/register-event';
import { registerPrivilegeCommand } from './commands/register-privilege';
import { generateApiCommand } from './commands/generate-api';
import { zmbCreateCommand } from './commands/zmb-create';

const program = new Command();

program
  .name('zorbit')
  .description('CLI tool for scaffolding and managing Zorbit platform services')
  .version('0.1.0');

createServiceCommand(program);
createModuleCommand(program);
registerEventCommand(program);
registerPrivilegeCommand(program);
generateApiCommand(program);
zmbCreateCommand(program);

program.parse(process.argv);
