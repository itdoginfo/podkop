declare global {
  const fs: {
    exec(
      command: string,
      args?: string[],
      env?: Record<string, string>,
    ): Promise<{
      stdout: string;
      stderr: string;
      code?: number;
    }>;
  };
}

export {};
