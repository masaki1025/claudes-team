/** HTTP client for communicating with the claude-peers broker. */

import type { BrokerSession, SessionInfo, BrokerMessage, BrokerLock } from "./types.js";

export class BrokerClient {
  private brokerUrl: string;
  private sessionId: string | null = null;
  private namespace: string;

  constructor(brokerUrl: string, namespace: string) {
    this.brokerUrl = brokerUrl;
    this.namespace = namespace;
  }

  getSessionId(): string {
    if (!this.sessionId) throw new Error("Not registered yet");
    return this.sessionId;
  }

  getNamespace(): string {
    return this.namespace;
  }

  private async request(path: string, options: RequestInit = {}): Promise<any> {
    const url = `${this.brokerUrl}${path}`;
    const resp = await fetch(url, {
      headers: { "Content-Type": "application/json", ...options.headers as any },
      ...options,
    });
    if (!resp.ok) {
      const body = await resp.text();
      throw new Error(`Broker error ${resp.status}: ${body}`);
    }
    return resp.json();
  }

  // --- Session management ---

  async register(
    role: string,
    workDir: string,
    channelUrl: string,
    gitRepo?: string
  ): Promise<string> {
    const data: BrokerSession = await this.request("/sessions", {
      method: "POST",
      body: JSON.stringify({
        role,
        namespace: this.namespace,
        work_dir: workDir,
        git_repo: gitRepo || null,
        channel_url: channelUrl,
      }),
    });
    this.sessionId = data.session_id;
    return data.session_id;
  }

  async unregister(): Promise<void> {
    if (!this.sessionId) return;
    try {
      await this.request(`/sessions/${this.sessionId}`, { method: "DELETE" });
    } catch {
      // Best effort
    }
  }

  async heartbeat(): Promise<void> {
    if (!this.sessionId) return;
    await this.request(`/sessions/${this.sessionId}/heartbeat`, { method: "PUT" });
  }

  async listPeers(): Promise<SessionInfo[]> {
    const data = await this.request(`/sessions?namespace=${encodeURIComponent(this.namespace)}`);
    return data.sessions;
  }

  async updateSummary(summary: string): Promise<void> {
    if (!this.sessionId) return;
    await this.request(`/sessions/${this.sessionId}/summary`, {
      method: "PUT",
      body: JSON.stringify({ summary }),
    });
  }

  // --- Messaging ---

  async sendMessage(toId: string, content: string): Promise<string> {
    const data = await this.request("/messages", {
      method: "POST",
      body: JSON.stringify({
        from_id: this.sessionId,
        to_id: toId,
        content,
      }),
    });
    return data.message_id;
  }

  async broadcast(content: string): Promise<string[]> {
    const data = await this.request("/messages/broadcast", {
      method: "POST",
      body: JSON.stringify({
        from_id: this.sessionId,
        content,
      }),
    });
    return data.delivered_to;
  }

  async checkMessages(): Promise<BrokerMessage[]> {
    if (!this.sessionId) return [];
    const data = await this.request(`/messages/${this.sessionId}`);
    return data.messages;
  }

  // --- File locks ---

  async lockFile(filePath: string): Promise<{ status: string; locked_by?: string; expires_at?: string }> {
    return this.request("/locks", {
      method: "POST",
      body: JSON.stringify({
        session_id: this.sessionId,
        file_path: filePath,
      }),
    });
  }

  async unlockFile(filePath: string): Promise<void> {
    await this.request(`/locks/${this.sessionId}/${encodeURIComponent(filePath)}`, {
      method: "DELETE",
    });
  }

  async getLocks(): Promise<BrokerLock[]> {
    const data = await this.request(`/locks?namespace=${encodeURIComponent(this.namespace)}`);
    return data.locks;
  }
}
