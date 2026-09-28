import { COMMAND_TIMEOUT } from '../constants';
import { withTimeout } from './withTimeout';

interface ExecuteShellCommandParams {
  command: string;
  args: string[];
  timeout?: number;
  // Send the call as its own HTTP request. LuCI merges RPC calls made within
  // one animation frame into a single request that rpcd runs one call after
  // another, so batched commands never overlap and all answer at once.
  nobatch?: boolean;
}

interface ExecuteShellCommandResponse {
  stdout: string;
  stderr: string;
  code?: number;
}

let execNoBatch:
  | ((
      command: string,
      args: string[],
    ) => Promise<ExecuteShellCommandResponse | number>)
  | undefined;

// Same ubus call as fs.exec, declared with nobatch. A non-object reply is the
// ubus status code of a failed call.
async function execWithoutBatching(
  command: string,
  args: string[],
): Promise<ExecuteShellCommandResponse> {
  execNoBatch ??= rpc.declare<ExecuteShellCommandResponse | number>({
    object: 'file',
    method: 'exec',
    params: ['command', 'params', 'env'],
    nobatch: true,
  });

  const reply = await execNoBatch(command, args);

  if (reply && typeof reply === 'object') {
    return reply;
  }

  return { stdout: '', stderr: `ubus status ${reply}`, code: Number(reply) };
}

export async function executeShellCommand({
  command,
  args,
  timeout = COMMAND_TIMEOUT,
  nobatch = false,
}: ExecuteShellCommandParams): Promise<ExecuteShellCommandResponse> {
  try {
    return withTimeout(
      nobatch ? execWithoutBatching(command, args) : fs.exec(command, args),
      timeout,
      [command, ...args].join(' '),
    );
  } catch (err) {
    const error = err as Error;

    return { stdout: '', stderr: error?.message, code: 0 };
  }
}
