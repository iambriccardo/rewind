import type { WebSocket } from 'ws';
import type { DeviceCommand, JsonObject, ServerMessage } from '../types.js';
import type { RewindRepository } from './RewindRepository.js';

type PendingAck = {
  resolve: (payload: JsonObject) => void;
  reject: (error: Error) => void;
  timeout: NodeJS.Timeout;
};

type DeviceConnection = {
  socket: WebSocket;
  pending: Map<string, PendingAck>;
};

export class DeviceCommandBus {
  private readonly connections = new Map<string, DeviceConnection>();

  constructor(private readonly repository: RewindRepository) {}

  register(deviceId: string, socket: WebSocket): void {
    this.connections.set(deviceId, { socket, pending: new Map() });
    socket.once('close', () => {
      const connection = this.connections.get(deviceId);
      if (connection?.socket === socket) {
        for (const [commandId, pending] of connection.pending) {
          clearTimeout(pending.timeout);
          pending.reject(new Error(`Device disconnected before ack: ${commandId}`));
        }
        this.connections.delete(deviceId);
      }
    });
  }

  async send(input: {
    session_id: string;
    user_id: string;
    device_id: string;
    command_type: string;
    payload: JsonObject;
    waitForAck?: boolean;
    timeoutMs?: number;
  }): Promise<{ command: DeviceCommand; ack?: JsonObject }> {
    const { waitForAck, timeoutMs, ...commandInput } = input;
    const command = await this.repository.createDeviceCommand(commandInput);
    const connection = this.connections.get(input.device_id);
    if (!connection || connection.socket.readyState !== connection.socket.OPEN) {
      await this.repository.updateDeviceCommandAck({
        command_id: command.id,
        status: 'failed',
        error: `No active WebSocket for device ${input.device_id}`
      });
      throw new Error(`No active WebSocket for device ${input.device_id}`);
    }

    command.status = 'sent';
    this.sendJson(connection.socket, { type: 'device.command', command });

    if (!waitForAck) {
      return { command };
    }

    const ack = await new Promise<JsonObject>((resolve, reject) => {
      const timeout = setTimeout(async () => {
        connection.pending.delete(command.id);
        await this.repository.updateDeviceCommandAck({
          command_id: command.id,
          status: 'timed_out',
          error: 'Timed out waiting for device acknowledgement'
        });
        reject(new Error(`Timed out waiting for ack: ${command.id}`));
      }, timeoutMs ?? 10_000);

      connection.pending.set(command.id, { resolve, reject, timeout });
    });

    return { command, ack };
  }

  async handleAck(input: { command_id: string; status: 'ok' | 'error'; payload?: JsonObject; error?: string }): Promise<void> {
    let pending: PendingAck | undefined;
    for (const connection of this.connections.values()) {
      pending = connection.pending.get(input.command_id);
      if (pending) {
        connection.pending.delete(input.command_id);
        break;
      }
    }

    await this.repository.updateDeviceCommandAck({
      command_id: input.command_id,
      status: input.status === 'ok' ? 'acknowledged' : 'failed',
      ack_payload: input.payload,
      error: input.error
    });

    if (pending) {
      clearTimeout(pending.timeout);
      if (input.status === 'ok') pending.resolve(input.payload ?? {});
      else pending.reject(new Error(input.error ?? 'Device command failed'));
    }
  }

  private sendJson(socket: WebSocket, message: ServerMessage): void {
    socket.send(JSON.stringify(message));
  }
}
