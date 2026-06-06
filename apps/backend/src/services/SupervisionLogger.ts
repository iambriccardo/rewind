import type { JsonObject } from '../types.js';
import type { RewindRepository } from './RewindRepository.js';

export class SupervisionLogger {
  constructor(private readonly repository: RewindRepository) {}

  async event(input: { session_id: string; user_id: string; type: string; payload: JsonObject }): Promise<void> {
    await this.repository.logAgentEvent(input).catch((error) => {
      console.error('failed to log agent event', error);
    });
  }

  async tool(input: {
    session_id: string;
    user_id: string;
    tool_name: string;
    tool_call_id?: string;
    arguments: JsonObject;
    result?: JsonObject;
    status: string;
    error?: string;
    latency_ms?: number;
  }): Promise<void> {
    await this.repository.logToolCall(input).catch((error) => {
      console.error('failed to log tool call', error);
    });
  }
}
