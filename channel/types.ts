/** Types for the claude-peers channel server. */

export interface SessionInfo {
  session_id: string;
  role: string;
  mode: string;
  work_dir: string;
  current_task: string | null;
  last_heartbeat: string;
}

export interface PushPayload {
  from_id: string;
  from_role: string;
  content: string;
  timestamp: string;
}

export interface ShutdownPayload {
  type: "shutdown";
  message: string;
}

export type IncomingPayload = PushPayload | ShutdownPayload;

export interface BrokerSession {
  status: string;
  session_id: string;
}

export interface BrokerMessage {
  message_id: string;
  from_id: string;
  content: string;
  timestamp: string;
}

export interface BrokerLock {
  file_path: string;
  session_id: string;
  role: string;
  acquired_at: string;
  expires_at: string;
}
