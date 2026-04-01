#!/bin/bash
cat << 'INNER_EOF' >> server/downloaders.ts

export class DelugeClient implements DownloaderClient {
  private downloader: Downloader;
  private cookie: string | null = null;
  private messageId: number = 0;

  constructor(downloader: Downloader) {
    this.downloader = downloader;
  }

  private async authenticate(): Promise<boolean> {
    if (!this.downloader.password) return true; // Some setups don't require auth

    const url = new URL("/json", this.downloader.url);
    const body = {
      method: "auth.login",
      params: [this.downloader.password],
      id: ++this.messageId,
    };

    try {
      const response = await safeFetch(url.toString(), {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "User-Agent": DOWNLOAD_CLIENT_USER_AGENT,
        },
        body: JSON.stringify(body),
      });

      if (!response.ok) {
        throw new Error(`HTTP error ${response.status}`);
      }

      const data = await response.json();
      if (data.error) {
        throw new Error(data.error.message || "Authentication failed");
      }

      const setCookie = response.headers.get("set-cookie");
      if (setCookie) {
        this.cookie = setCookie.split(";")[0];
      }
      return data.result === true;
    } catch (error: any) {
      downloadersLogger.error({ error: error.message }, "Deluge authentication failed");
      return false;
    }
  }

  private async rpcCall(method: string, params: any[] = []): Promise<any> {
    const makeRequest = async () => {
      const url = new URL("/json", this.downloader.url);
      const headers: Record<string, string> = {
        "Content-Type": "application/json",
        "User-Agent": DOWNLOAD_CLIENT_USER_AGENT,
      };

      if (this.cookie) {
        headers["Cookie"] = this.cookie;
      }

      const body = {
        method,
        params,
        id: ++this.messageId,
      };

      const response = await safeFetch(url.toString(), {
        method: "POST",
        headers,
        body: JSON.stringify(body),
      });

      if (!response.ok) {
        throw new Error(`HTTP error ${response.status}`);
      }

      const data = await response.json();
      if (data.error) {
        throw new Error(data.error.message || `RPC error in ${method}`);
      }
      return data.result;
    };

    try {
      if (!this.cookie) {
        await this.authenticate();
      }
      return await makeRequest();
    } catch (error: any) {
      if (error.message.includes("Not authenticated") || error.message.includes("HTTP error 401")) {
        await this.authenticate();
        return await makeRequest();
      }
      throw error;
    }
  }

  async testConnection(): Promise<{ success: boolean; message: string }> {
    try {
      const authSuccess = await this.authenticate();
      if (!authSuccess) {
        return { success: false, message: "Authentication failed. Check your password." };
      }
      await this.rpcCall("daemon.info");
      return { success: true, message: "Successfully connected to Deluge" };
    } catch (error: any) {
      return { success: false, message: `Connection failed: ${error.message}` };
    }
  }

  async addDownload(request: DownloadRequest): Promise<{ success: boolean; id?: string; message: string }> {
    try {
      const options: any = {};
      if (this.downloader.downloadPath) {
        options.download_location = this.downloader.downloadPath;
      }

      let result;
      if (request.magnetUrl) {
        result = await this.rpcCall("core.add_torrent_magnet", [request.magnetUrl, options]);
      } else if (request.fileBuffer) {
        const fileContent = request.fileBuffer.toString("base64");
        result = await this.rpcCall("core.add_torrent_file", ["torrent.torrent", fileContent, options]);
      } else {
        return { success: false, message: "No download URL or file provided" };
      }

      if (!result) {
        return { success: false, message: "Failed to add torrent" };
      }

      if (this.downloader.label) {
        try {
          await this.rpcCall("label.set_torrent", [result, this.downloader.label]);
        } catch (labelError) {
          downloadersLogger.warn({ error: labelError }, "Failed to set label (label plugin might not be enabled)");
        }
      }

      return { success: true, id: result, message: "Torrent added successfully" };
    } catch (error: any) {
      return { success: false, message: `Failed to add download: ${error.message}` };
    }
  }

  async getDownloadStatus(id: string): Promise<DownloadStatus | null> {
    try {
      const keys = ["state", "progress", "download_payload_rate", "eta", "total_size", "name"];
      const result = await this.rpcCall("core.get_torrent_status", [id, keys]);

      if (!result || Object.keys(result).length === 0) return null;

      let status: "downloading" | "completed" | "wanted" = "downloading";
      if (result.state === "Seeding" || result.state === "Paused" && result.progress === 100) {
        status = "completed";
      }

      return {
        id,
        status,
        progress: result.progress || 0,
        downloadSpeed: result.download_payload_rate || 0,
        eta: result.eta || 0,
        totalSize: result.total_size || 0,
      };
    } catch (error) {
      return null;
    }
  }

  async getDownloadDetails(id: string): Promise<DownloadDetails | null> {
    try {
      const keys = ["name", "state", "progress", "download_payload_rate", "eta", "total_size", "total_done", "total_uploaded", "ratio"];
      const result = await this.rpcCall("core.get_torrent_status", [id, keys]);

      if (!result || Object.keys(result).length === 0) return null;

      let status: "downloading" | "completed" | "wanted" = "downloading";
      if (result.state === "Seeding" || result.state === "Paused" && result.progress === 100) {
        status = "completed";
      }

      return {
        id,
        name: result.name || "Unknown Download",
        status,
        progress: result.progress || 0,
        downloadSpeed: result.download_payload_rate || 0,
        eta: result.eta || 0,
        totalSize: result.total_size || 0,
        downloaded: result.total_done || 0,
        uploaded: result.total_uploaded || 0,
        ratio: result.ratio || 0,
        files: [],
      };
    } catch (error) {
      return null;
    }
  }

  async getAllDownloads(): Promise<DownloadStatus[]> {
    try {
      const keys = ["state", "progress", "download_payload_rate", "eta", "total_size"];
      const result = await this.rpcCall("core.get_torrents_status", [{}, keys]);

      if (!result) return [];

      return Object.entries(result).map(([id, data]: [string, any]) => {
        let status: "downloading" | "completed" | "wanted" = "downloading";
        if (data.state === "Seeding" || data.state === "Paused" && data.progress === 100) {
          status = "completed";
        }

        return {
          id,
          status,
          progress: data.progress || 0,
          downloadSpeed: data.download_payload_rate || 0,
          eta: data.eta || 0,
          totalSize: data.total_size || 0,
        };
      });
    } catch (error) {
      return [];
    }
  }

  async pauseDownload(id: string): Promise<{ success: boolean; message: string }> {
    try {
      await this.rpcCall("core.pause_torrent", [[id]]);
      return { success: true, message: "Download paused" };
    } catch (error: any) {
      return { success: false, message: `Failed to pause download: ${error.message}` };
    }
  }

  async resumeDownload(id: string): Promise<{ success: boolean; message: string }> {
    try {
      await this.rpcCall("core.resume_torrent", [[id]]);
      return { success: true, message: "Download resumed" };
    } catch (error: any) {
      return { success: false, message: `Failed to resume download: ${error.message}` };
    }
  }

  async removeDownload(id: string, deleteFiles: boolean = false): Promise<{ success: boolean; message: string }> {
    try {
      await this.rpcCall("core.remove_torrent", [id, deleteFiles]);
      return { success: true, message: "Download removed" };
    } catch (error: any) {
      return { success: false, message: `Failed to remove download: ${error.message}` };
    }
  }

  async getFreeSpace(): Promise<number> {
    try {
      const path = this.downloader.downloadPath || "/";
      const result = await this.rpcCall("core.get_free_space", [path]);
      return result || 0;
    } catch (error) {
      return 0;
    }
  }
}
INNER_EOF
