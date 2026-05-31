declare module '@earendil-works/pi-coding-agent' {
  export interface ExtensionAPI {
    on(event: string, handler: (...args: any[]) => any): void;
    exec(cmd: string, args: string[], opts?: { timeout?: number }): Promise<{ code: number; stdout: string; stderr: string }>;
  }
  export interface PI {}
}
